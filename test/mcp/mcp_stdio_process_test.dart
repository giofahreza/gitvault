import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory sandbox;
  late Directory base;
  late String dart;
  const profileId = 'test-client';
  const canary = 'private-token-and-note-canary';

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('gitvault-bridge-');
    base = Directory(Platform.isMacOS
        ? p.join(
            sandbox.path, 'Library', 'Application Support', 'GitVault', 'mcp')
        : Platform.isWindows
            ? p.join(sandbox.path, 'GitVault', 'mcp')
            : p.join(sandbox.path, 'gitvault', 'mcp'));
    await Directory(p.join(base.path, 'profiles')).create(recursive: true);
    final candidates = [
      Platform.environment['GITVAULT_TEST_DART'],
      p.join(p.dirname(Platform.resolvedExecutable),
          Platform.isWindows ? 'dart.exe' : 'dart'),
      p.normalize(p.join(p.dirname(Platform.resolvedExecutable), '..', '..',
          '..', 'dart-sdk', 'bin', Platform.isWindows ? 'dart.exe' : 'dart')),
    ];
    dart = candidates.whereType<String>().firstWhere(
        (path) => File(path).existsSync(),
        orElse: () =>
            throw StateError('Set GITVAULT_TEST_DART to the local SDK.'));
  });
  tearDown(() async => sandbox.delete(recursive: true));

  Map<String, String> environment() => {
        ...Platform.environment,
        'HOME': sandbox.path,
        'APPDATA': sandbox.path,
        'XDG_CONFIG_HOME': sandbox.path,
      };
  Future<void> writeConfig({String? endpoint, String? profile}) async {
    await File(p.join(base.path, 'discovery.json')).writeAsString(jsonEncode({
      'endpoint': endpoint ?? 'http://127.0.0.1:1/mcp',
    }));
    await File(p.join(base.path, 'profiles', '$profileId.json')).writeAsString(
        profile ?? jsonEncode({'client_id': profileId, 'token': canary}));
  }

  Future<ProcessResult> run([List<String>? args]) => Process.run(
          dart,
          [
            'run',
            'bin/gitvault_mcp.dart',
            ...(args ?? ['--profile', profileId])
          ],
          workingDirectory: Directory.current.path,
          environment: environment())
      .timeout(const Duration(seconds: 30));

  for (final scenario in ['normal', 'blocked']) {
    test('MCP-GAP-018 isolated directory/profile persistence $scenario',
        () async {
      if (scenario == 'blocked') await base.delete(recursive: true);
      final result = await Process.run(
          dart, ['run', 'test/support/mcp_paths_probe.dart', scenario],
          workingDirectory: Directory.current.path, environment: environment());
      expect(result.exitCode, scenario == 'normal' ? 0 : 73);
      expect(result.stdout,
          scenario == 'normal' ? 'verified\n' : 'storage-unavailable\n');
      expect(result.stderr, isEmpty);
    });
  }

  for (final scenario in ['chmod-exit', 'chmod-missing']) {
    test('MCP-GAP-018 permission command failure rejects $scenario', () async {
      final commandDirectory = Directory(p.join(sandbox.path, 'commands'));
      await commandDirectory.create();
      if (scenario == 'chmod-exit') {
        final command = File(p.join(commandDirectory.path, 'chmod'));
        await command.writeAsString('#!/bin/sh\nexit 1\n');
        expect(
            (await Process.run('/bin/chmod', ['700', command.path])).exitCode,
            0);
      }
      final result = await Process.run(
          dart, ['test/support/mcp_paths_probe.dart', scenario],
          workingDirectory: Directory.current.path,
          environment: {...environment(), 'PATH': commandDirectory.path});
      expect(result.exitCode, 73, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, 'storage-unavailable\n');
      expect(result.stderr, isEmpty);
      expect(await File(p.join(base.path, 'profiles', 'profile.json')).exists(),
          false,
          reason: 'Do not write credentials without secured directories');
    }, skip: Platform.isWindows ? 'POSIX command injection' : false);
  }

  for (final scenario in [
    'missing-argument',
    'path-traversal',
    'missing-discovery',
    'missing-profile',
    'malformed-discovery',
    'malformed-profile',
    'profile-array',
    'wrong-client',
    'empty-token',
    'external-host',
    'stale-endpoint',
  ]) {
    test('MCP-GAP-003/013/017 bridge process $scenario', () async {
      await writeConfig();
      var exit = 70;
      List<String>? arguments;
      switch (scenario) {
        case 'missing-argument':
          arguments = ['--profile'];
          exit = 64;
        case 'path-traversal':
          arguments = ['--profile', '../$canary'];
          exit = 64;
        case 'missing-discovery':
          await File(p.join(base.path, 'discovery.json')).delete();
          exit = 69;
        case 'missing-profile':
          await File(p.join(base.path, 'profiles', '$profileId.json')).delete();
          exit = 69;
        case 'malformed-discovery':
          await File(p.join(base.path, 'discovery.json'))
              .writeAsString('{"secret":"$canary",broken');
        case 'malformed-profile':
          await writeConfig(profile: '{"token":"$canary",broken');
        case 'profile-array':
          await writeConfig(profile: jsonEncode([canary]));
        case 'wrong-client':
          await writeConfig(
              profile: jsonEncode({'client_id': 'other', 'token': canary}));
        case 'empty-token':
          await writeConfig(
              profile: jsonEncode({'client_id': profileId, 'token': ''}));
        case 'external-host':
          await writeConfig(endpoint: 'http://192.0.2.1:1/mcp');
        case 'stale-endpoint':
          exit = 69;
      }
      final result = await run(arguments);
      expect(result.exitCode, exit);
      expect(result.stdout, isEmpty);
      expect(result.stderr, isNot(contains(canary)));
      expect(result.stderr, contains('GitVault MCP'));
    }, timeout: const Timeout(Duration(minutes: 1)));
  }

  test('MCP-GAP-013/014 two independent bridge processes and restart',
      () async {
    silenceMcpLogs();
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sessions = <String, StreamableHTTPServerTransport>{};
    final servers = <McpServer>[];
    var authorized = 0;
    http.listen((request) async {
      if (request.headers.value('authorization') != 'Bearer $canary') {
        request.response.statusCode = 401;
        await request.response.close();
        return;
      }
      authorized++;
      final id = request.headers.value('mcp-session-id');
      if (id != null && sessions[id] != null) {
        await sessions[id]!.handleRequest(request);
        return;
      }
      late StreamableHTTPServerTransport transport;
      transport = StreamableHTTPServerTransport(
          options: StreamableHTTPServerTransportOptions(
        sessionIdGenerator: generateUUID,
        onsessioninitialized: (id) => sessions[id] = transport,
      ));
      final server = McpServer(
          const Implementation(name: 'fixture', version: '1'),
          options: const McpServerOptions(
              protocol: McpProtocol.stable,
              capabilities:
                  ServerCapabilities(tools: ServerCapabilitiesTools())));
      server.registerTool('echo',
          inputSchema: JsonObject(properties: {
            'value': JsonString(),
          }),
          callback: (args, _) async => CallToolResult(content: [
                TextContent(text: args['value'] as String? ?? 'empty'),
              ]));
      servers.add(server);
      await server.connect(transport);
      await transport.handleRequest(request);
    });
    addTearDown(() async {
      for (final server in servers) {
        await server.close();
      }
      await http.close(force: true);
    });
    await writeConfig(endpoint: 'http://127.0.0.1:${http.port}/mcp');
    Future<McpClient> connect(String name) async {
      final client = McpClient(Implementation(name: name, version: '1'),
          options: const McpClientOptions(protocol: McpProtocol.stable));
      final transport = StdioClientTransport(StdioServerParameters(
          command: dart,
          args: ['run', 'bin/gitvault_mcp.dart', '--profile', profileId],
          environment: environment(),
          workingDirectory: Directory.current.path));
      await client.connect(transport);
      addTearDown(client.close);
      return client;
    }

    final first = await connect('first');
    final second = await connect('second');
    expect((await first.listTools()).tools.single.name, 'echo');
    expect((await second.listTools()).tools.single.name, 'echo');
    for (final client in [first, second]) {
      final response = await client.callTool(const CallToolRequest(
          name: 'echo', arguments: {'value': 'Unicode 🔐\nsecond line'}));
      expect((response.content.single as TextContent).text,
          'Unicode 🔐\nsecond line');
    }
    await first.close();
    final replacement = await connect('replacement');
    expect((await replacement.listTools()).tools.single.name, 'echo');
    expect((await second.listTools()).tools.single.name, 'echo');
    expect(authorized, greaterThan(6));

    // Exercise OS pipes directly: SDK clients normally hide fragmentation,
    // coalesced frames, malformed bytes and host EOF from their callers.
    final raw = await Process.start(
        dart, ['run', 'bin/gitvault_mcp.dart', '--profile', profileId],
        environment: environment(), workingDirectory: Directory.current.path);
    addTearDown(() => raw.kill());
    final messages = <Map<String, dynamic>>[];
    final subscription = raw.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      messages.add(jsonDecode(line) as Map<String, dynamic>);
    });
    addTearDown(subscription.cancel);
    final stderr = raw.stderr.transform(utf8.decoder).join();
    Future<Map<String, dynamic>> reply(int id) async {
      for (var i = 0; i < 200; i++) {
        final matching = messages.where((message) => message['id'] == id);
        if (matching.isNotEmpty) return matching.single;
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      throw StateError('No JSON-RPC response for $id');
    }

    final initialize = utf8.encode('${jsonEncode({
          'jsonrpc': '2.0',
          'id': 100,
          'method': 'initialize',
          'params': {
            'protocolVersion': '2025-06-18',
            'capabilities': {},
            'clientInfo': {'name': 'fragmented 🔐 host', 'version': '1'}
          },
        })}\n');
    for (final byte in initialize) {
      raw.stdin.add([byte]);
      await raw.stdin.flush();
    }
    expect((await reply(100))['result'], isA<Map>());
    Map<String, dynamic> echo(int id, String text) => {
          'jsonrpc': '2.0',
          'id': id,
          'method': 'tools/call',
          'params': {
            'name': 'echo',
            'arguments': {'value': text}
          },
        };
    raw.stdin.write('${jsonEncode({
          'jsonrpc': '2.0',
          'method': 'notifications/initialized'
        })}\n'
        '${jsonEncode(echo(101, 'first 🔐\nline'))}\n'
        '${jsonEncode(echo(102, 'second'))}\n');
    await raw.stdin.flush();
    expect(((await reply(101))['result']['content'] as List).single['text'],
        'first 🔐\nline');
    expect(((await reply(102))['result']['content'] as List).single['text'],
        'second');
    raw.stdin.write('{"secret":"$canary",broken\n');
    raw.stdin.add([0xff, 10]);
    raw.stdin.write('[]\nnull\n${jsonEncode(echo(103, 'still usable'))}\n');
    await raw.stdin.flush();
    expect(((await reply(103))['result']['content'] as List).single['text'],
        'still usable');
    final errors = messages.where((message) => message.containsKey('error'));
    expect(errors.length, greaterThanOrEqualTo(4));
    expect(jsonEncode(errors.toList()), isNot(contains(canary)));
    expect(jsonEncode(errors.toList()).length, lessThan(2048));
    final errorCount = errors.length;
    // JSON whitespace is legal, so schema validation alone cannot enforce a
    // wire-frame bound. Oversized input must not execute its valid prefix.
    raw.stdin.write('${jsonEncode(echo(104, 'must not execute'))}'
        '${' ' * (1024 * 1024)}\n'
        '${jsonEncode(echo(105, 'after oversized frame'))}\n');
    await raw.stdin.flush();
    await reply(105);
    expect(messages.where((m) => m['id'] == 104), isEmpty);
    expect(errors.length, errorCount + 1);
    // Reject as soon as the bound is crossed, even without a line terminator.
    raw.stdin.write(' ' * (1024 * 1024 + 1));
    await raw.stdin.flush();
    for (var i = 0; i < 200 && errors.length == errorCount + 1; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(errors.length, errorCount + 2);
    raw.stdin.write('\n${jsonEncode(echo(106, 'after oversized partial'))}\n');
    await raw.stdin.flush();
    await reply(106);
    // A host can disappear halfway through its next JSON frame.
    raw.stdin.write('{"jsonrpc":"2.0","secret":"$canary"');
    await raw.stdin.close();
    expect(await raw.exitCode.timeout(const Duration(seconds: 5)), 0);
    expect(await stderr, isNot(contains(canary)));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
