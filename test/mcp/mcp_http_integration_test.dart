import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitvault/core/session/vault_session_controller.dart';
import 'package:gitvault/mcp/mcp_approval_controller.dart';
import 'package:gitvault/mcp/mcp_client_registry.dart';
import 'package:gitvault/mcp/mcp_desktop_server.dart';
import 'package:gitvault/mcp/mcp_models.dart';
import 'package:gitvault/mcp/mcp_server_factory.dart';
import 'package:gitvault/mcp/notes_mcp_service.dart';
import 'package:http/http.dart' as http;
import 'package:mcp_dart/mcp_dart.dart';

import 'test_support.dart';

const _maximumRequestBytes = 1024 * 1024;
const _requestsPerMinute = 120;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory hiveDirectory;

  setUpAll(() async {
    HttpOverrides.global = null;
    hiveDirectory = await initializeTestHive();
  });

  setUp(resetMcpBoxes);

  tearDown(() async {
    await resetMcpBoxes();
  });

  tearDownAll(() async {
    await closeTestHive(hiveDirectory);
  });

  test('HTTP MCP authenticates and enforces live lock state', () async {
    final registry = McpClientRegistry();
    final approvals = McpApprovalController();
    var session = VaultSessionState(
      status: VaultSessionStatus.unlocked,
      changedAt: DateTime.now(),
      generation: 1,
    );
    final repository = MemoryNotesRepository([
      testNote(id: 'visible', title: 'Visible note'),
    ]);
    final notesService = NotesMcpService(
      notesRepository: repository,
      registry: registry,
      approvalController: approvals,
      readSession: () => session,
    );
    final factory = GitVaultMcpServerFactory(
      registry: registry,
      notesService: notesService,
      version: 'test',
    );
    final server = McpDesktopServer(
      registry: registry,
      approvalController: approvals,
      serverFactory: factory,
      readSession: () => session,
    );

    final issued = await registry.createClient(
      displayName: 'Integration client',
      transport: McpClientTransport.streamableHttp,
      permissions: const {
        McpPermission.readMetadata,
        McpPermission.readContent,
        McpPermission.search,
      },
    );
    await registry.setEnabled(true);
    await server.initialize();
    addTearDown(() async {
      await server.stop();
      server.dispose();
      approvals.dispose();
    });

    final endpoint = server.state.endpoint!;
    final unauthorized = await http.post(
      endpoint,
      headers: {'content-type': 'application/json'},
      body: '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}',
    );
    expect(unauthorized.statusCode, HttpStatus.unauthorized);

    final client = McpClient(
      const Implementation(name: 'integration-test', version: '1'),
      options: const McpClientOptions(protocol: McpProtocol.stable),
    );
    final transport = StreamableHttpClientTransport(
      endpoint,
      opts: StreamableHttpClientTransportOptions(
        requestInit: {
          'headers': {'Authorization': 'Bearer ${issued.token}'},
        },
      ),
    );
    await client.connect(transport);
    addTearDown(client.close);

    final tools = await client.listTools();
    expect(tools.tools.map((tool) => tool.name), contains('list_notes'));
    for (final toolName in [
      'list_notes',
      'list_note_tags',
      'search_notes',
      'get_note',
    ]) {
      final tool = tools.tools.singleWhere((tool) => tool.name == toolName);
      expect(tool.annotations?.readOnlyHint, isTrue, reason: toolName);
      expect(tool.annotations?.destructiveHint, isFalse, reason: toolName);
      expect(tool.annotations?.idempotentHint, isTrue, reason: toolName);
      expect(tool.annotations?.openWorldHint, isFalse, reason: toolName);
    }

    final unlocked = await client.callTool(
      const CallToolRequest(name: 'list_notes', arguments: {}),
    );
    expect(unlocked.isError, isFalse);
    expect(unlocked.structuredContent!['total'], 1);

    session = VaultSessionState(
      status: VaultSessionStatus.locked,
      changedAt: DateTime.now(),
      generation: 2,
    );
    server.handleSessionChanged(session);
    final locked = await client.callTool(
      const CallToolRequest(name: 'list_notes', arguments: {}),
    );
    expect(locked.isError, isTrue);
    expect(
      ((locked.structuredContent!['error'] as Map)['code']),
      'vault_locked',
    );
  });

  test('allow always completes the active write and exempts the next one',
      () async {
    final registry = McpClientRegistry();
    final approvals = McpApprovalController();
    final session = VaultSessionState(
      status: VaultSessionStatus.unlocked,
      changedAt: DateTime.now(),
      generation: 1,
    );
    final repository = MemoryNotesRepository(const []);
    final notesService = NotesMcpService(
      notesRepository: repository,
      registry: registry,
      approvalController: approvals,
      readSession: () => session,
    );
    final factory = GitVaultMcpServerFactory(
      registry: registry,
      notesService: notesService,
      version: 'test',
    );
    final server = McpDesktopServer(
      registry: registry,
      approvalController: approvals,
      serverFactory: factory,
      readSession: () => session,
    );

    final issued = await registry.createClient(
      displayName: 'Approval client',
      transport: McpClientTransport.streamableHttp,
      permissions: const {McpPermission.create},
    );
    await registry.setEnabled(true);
    await server.initialize();
    addTearDown(() async {
      await server.stop();
      server.dispose();
      approvals.dispose();
    });

    final client = McpClient(
      const Implementation(name: 'approval-test', version: '1'),
      options: const McpClientOptions(protocol: McpProtocol.stable),
    );
    final transport = StreamableHttpClientTransport(
      server.state.endpoint!,
      opts: StreamableHttpClientTransportOptions(
        requestInit: {
          'headers': {'Authorization': 'Bearer ${issued.token}'},
        },
      ),
    );
    await client.connect(transport);
    addTearDown(client.close);

    final firstWrite = client.callTool(
      const CallToolRequest(
        name: 'create_note',
        arguments: {'title': 'First', 'content': 'Approved once'},
      ),
    );
    final approval = await _waitForApproval(approvals);
    approvals.resolve(approval.id, McpApprovalDecision.allowAlways);

    final firstResult = await firstWrite;
    expect(firstResult.isError, isFalse);
    expect(repository.notes.values.single.title, 'First');
    expect(
      registry
          .getClient(issued.client.id)!
          .approvalExemptPermissions
          .contains(McpPermission.create),
      isTrue,
    );

    final secondResult = await client.callTool(
      const CallToolRequest(
        name: 'create_note',
        arguments: {'title': 'Second', 'content': 'No new approval'},
      ),
    );
    expect(secondResult.isError, isFalse);
    expect(approvals.pending, isEmpty);
    expect(repository.notes.values.map((note) => note.title), {
      'First',
      'Second',
    });
  });

  test('HTTP credential rotation and revocation invalidate access', () async {
    final registry = McpClientRegistry();
    final approvals = McpApprovalController();
    final session = VaultSessionState(
      status: VaultSessionStatus.unlocked,
      changedAt: DateTime.now(),
      generation: 1,
    );
    final notesService = NotesMcpService(
      notesRepository: MemoryNotesRepository(const []),
      registry: registry,
      approvalController: approvals,
      readSession: () => session,
    );
    final server = McpDesktopServer(
      registry: registry,
      approvalController: approvals,
      serverFactory: GitVaultMcpServerFactory(
        registry: registry,
        notesService: notesService,
        version: 'test',
      ),
      readSession: () => session,
    );
    final issued = await registry.createClient(
      displayName: 'Rotating client',
      transport: McpClientTransport.streamableHttp,
      permissions: const {McpPermission.readMetadata},
    );
    await registry.setEnabled(true);
    await server.initialize();
    addTearDown(() async {
      await server.stop();
      server.dispose();
      approvals.dispose();
    });

    final firstResponse =
        await _initializeWithToken(server.state.endpoint!, issued.token);
    expect(firstResponse.statusCode, HttpStatus.ok);
    expect(server.state.activeSessions, 1);

    final rotated = await registry.rotateCredential(issued.client.id);
    await _waitForSessionsToClose(server);
    final oldCredential =
        await _initializeWithToken(server.state.endpoint!, issued.token);
    expect(oldCredential.statusCode, HttpStatus.unauthorized);
    final newCredential =
        await _initializeWithToken(server.state.endpoint!, rotated.token);
    expect(newCredential.statusCode, HttpStatus.ok);
    expect(server.state.activeSessions, 1);

    await registry.revokeClient(issued.client.id);
    await _waitForSessionsToClose(server);
    final revoked =
        await _initializeWithToken(server.state.endpoint!, rotated.token);
    expect(revoked.statusCode, HttpStatus.unauthorized);
  });

  test('denied HTTP write leaves notes unchanged and records denial', () async {
    final registry = McpClientRegistry();
    final approvals = McpApprovalController();
    final session = VaultSessionState(
      status: VaultSessionStatus.unlocked,
      changedAt: DateTime.now(),
      generation: 1,
    );
    final repository = MemoryNotesRepository(const []);
    final notesService = NotesMcpService(
      notesRepository: repository,
      registry: registry,
      approvalController: approvals,
      readSession: () => session,
    );
    final server = McpDesktopServer(
      registry: registry,
      approvalController: approvals,
      serverFactory: GitVaultMcpServerFactory(
        registry: registry,
        notesService: notesService,
        version: 'test',
      ),
      readSession: () => session,
    );
    final issued = await registry.createClient(
      displayName: 'Denied client',
      transport: McpClientTransport.streamableHttp,
      permissions: const {McpPermission.create},
    );
    await registry.setEnabled(true);
    await server.initialize();
    addTearDown(() async {
      await server.stop();
      server.dispose();
      approvals.dispose();
    });

    final client = McpClient(
      const Implementation(name: 'denial-test', version: '1'),
      options: const McpClientOptions(protocol: McpProtocol.stable),
    );
    await client.connect(
      StreamableHttpClientTransport(
        server.state.endpoint!,
        opts: StreamableHttpClientTransportOptions(
          requestInit: {
            'headers': {'Authorization': 'Bearer ${issued.token}'},
          },
        ),
      ),
    );
    addTearDown(client.close);

    final write = client.callTool(
      const CallToolRequest(
        name: 'create_note',
        arguments: {'title': 'Denied', 'content': 'Must not be saved'},
      ),
    );
    final approval = await _waitForApproval(approvals);
    approvals.resolve(approval.id, McpApprovalDecision.deny);

    final result = await write;
    expect(result.isError, isTrue);
    expect(
      (result.structuredContent!['error'] as Map)['code'],
      'approval_denied',
    );
    expect(repository.notes, isEmpty);
    expect(registry.activity, hasLength(1));
    expect(registry.activity.single.result, McpActivityResult.denied);
  });

  test(
      'HTTP boundary rejects origins, invalid hosts, oversized bodies, and floods',
      () async {
    final registry = McpClientRegistry();
    final approvals = McpApprovalController();
    final session = VaultSessionState(
      status: VaultSessionStatus.unlocked,
      changedAt: DateTime.now(),
      generation: 1,
    );
    final notesService = NotesMcpService(
      notesRepository: MemoryNotesRepository(const []),
      registry: registry,
      approvalController: approvals,
      readSession: () => session,
    );
    final server = McpDesktopServer(
      registry: registry,
      approvalController: approvals,
      serverFactory: GitVaultMcpServerFactory(
        registry: registry,
        notesService: notesService,
        version: 'test',
      ),
      readSession: () => session,
    );
    final issued = await registry.createClient(
      displayName: 'Boundary client',
      transport: McpClientTransport.streamableHttp,
      permissions: const {McpPermission.readMetadata},
    );
    final floodClient = await registry.createClient(
      displayName: 'Flood client',
      transport: McpClientTransport.streamableHttp,
      permissions: const {McpPermission.readMetadata},
    );
    await registry.setEnabled(true);
    await server.initialize();
    addTearDown(() async {
      await server.stop();
      server.dispose();
      approvals.dispose();
    });
    final endpoint = server.state.endpoint!;

    final origin = await http.post(
      endpoint,
      headers: {
        HttpHeaders.authorizationHeader: 'Bearer ${issued.token}',
        HttpHeaders.contentTypeHeader: 'application/json',
        'origin': 'https://attacker.example',
      },
      body: '{}',
    );
    expect(origin.statusCode, HttpStatus.forbidden);

    final ioClient = HttpClient();
    addTearDown(() => ioClient.close(force: true));
    final hostRequest = await ioClient.postUrl(endpoint);
    hostRequest.headers
      ..set(HttpHeaders.hostHeader, 'attacker.example')
      ..set(HttpHeaders.authorizationHeader, 'Bearer ${issued.token}')
      ..contentType = ContentType.json;
    hostRequest.write('{}');
    final invalidHost = await hostRequest.close();
    expect(invalidHost.statusCode, HttpStatus.forbidden);
    await invalidHost.drain<void>();

    final oversized = await http.post(
      endpoint,
      headers: {
        HttpHeaders.authorizationHeader: 'Bearer ${issued.token}',
        HttpHeaders.contentTypeHeader: 'application/json',
        HttpHeaders.acceptHeader: 'application/json, text/event-stream',
      },
      body: 'x' * (_maximumRequestBytes + 1),
    );
    expect(oversized.statusCode, HttpStatus.ok);
    final oversizedJson = jsonDecode(oversized.body) as Map<String, dynamic>;
    expect(
      ((oversizedJson['error'] as Map)['data'] as Map)['code'],
      'invalid_input',
    );

    for (var request = 0; request < _requestsPerMinute; request++) {
      final response = await http.get(
        endpoint,
        headers: {
          HttpHeaders.authorizationHeader: 'Bearer ${floodClient.token}',
        },
      );
      expect(response.statusCode, HttpStatus.badRequest);
    }
    final rateLimited = await http.get(
      endpoint,
      headers: {
        HttpHeaders.authorizationHeader: 'Bearer ${floodClient.token}',
      },
    );
    expect(rateLimited.statusCode, HttpStatus.tooManyRequests);
  });

  test(
    'stdio bridge reports Desktop unavailable after the server quits',
    () async {
      if (!Platform.isLinux) return;

      final registry = McpClientRegistry();
      final approvals = McpApprovalController();
      final session = VaultSessionState(
        status: VaultSessionStatus.unlocked,
        changedAt: DateTime.now(),
        generation: 1,
      );
      final notesService = NotesMcpService(
        notesRepository: MemoryNotesRepository(const []),
        registry: registry,
        approvalController: approvals,
        readSession: () => session,
      );
      final server = McpDesktopServer(
        registry: registry,
        approvalController: approvals,
        serverFactory: GitVaultMcpServerFactory(
          registry: registry,
          notesService: notesService,
          version: 'test',
        ),
        readSession: () => session,
      );
      final issued = await registry.createClient(
        displayName: 'Stdio quit client',
        transport: McpClientTransport.stdio,
        permissions: const {McpPermission.readMetadata},
      );
      await registry.setEnabled(true);
      await server.initialize();
      final staleEndpoint = server.state.endpoint!;
      await server.stop();
      server.dispose();
      approvals.dispose();

      final configRoot =
          await Directory.systemTemp.createTemp('gitvault-stdio-quit-');
      addTearDown(() async {
        if (await configRoot.exists()) {
          await configRoot.delete(recursive: true);
        }
      });
      final mcpDirectory =
          Directory('${configRoot.path}/gitvault/mcp/profiles');
      await mcpDirectory.create(recursive: true);
      await File('${configRoot.path}/gitvault/mcp/discovery.json')
          .writeAsString(jsonEncode({'endpoint': staleEndpoint.toString()}));
      await File('${mcpDirectory.path}/${issued.client.id}.json').writeAsString(
        jsonEncode({
          'client_id': issued.client.id,
          'token': issued.token,
        }),
      );

      final dart = _findDartExecutable();
      expect(dart, isNotNull, reason: 'Dart executable is required.');
      final result = await Process.run(
        dart!,
        ['run', 'bin/gitvault_mcp.dart', '--profile', issued.client.id],
        workingDirectory: Directory.current.path,
        environment: {
          ...Platform.environment,
          'XDG_CONFIG_HOME': configRoot.path,
        },
      ).timeout(const Duration(seconds: 30));

      expect(result.exitCode, 69);
      expect(
        result.stderr,
        contains('could not connect to GitVault Desktop'),
      );
      expect(result.stdout, isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
}

Future<McpApprovalRequest> _waitForApproval(
  McpApprovalController controller,
) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    final request = controller.nextRequest;
    if (request != null) return request;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('Approval request was not created.');
}

Future<http.Response> _initializeWithToken(Uri endpoint, String token) {
  return http.post(
    endpoint,
    headers: {
      HttpHeaders.authorizationHeader: 'Bearer $token',
      HttpHeaders.contentTypeHeader: 'application/json',
      HttpHeaders.acceptHeader: 'application/json, text/event-stream',
    },
    body: jsonEncode({
      'jsonrpc': '2.0',
      'id': 1,
      'method': Method.initialize,
      'params': {
        'protocolVersion': latestInitializationProtocolVersion,
        'capabilities': <String, dynamic>{},
        'clientInfo': {'name': 'credential-test', 'version': '1'},
      },
    }),
  );
}

String? _findDartExecutable() {
  final executableName = Platform.isWindows ? 'dart.exe' : 'dart';
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null) {
    final candidate =
        File('$flutterRoot/bin/cache/dart-sdk/bin/$executableName');
    if (candidate.existsSync()) return candidate.path;
  }

  var directory = File(Platform.resolvedExecutable).parent;
  for (var level = 0; level < 10; level++) {
    final candidate =
        File('${directory.path}/bin/cache/dart-sdk/bin/$executableName');
    if (candidate.existsSync()) return candidate.path;
    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }
  return null;
}

Future<void> _waitForSessionsToClose(McpDesktopServer server) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (server.state.activeSessions == 0) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('MCP sessions were not closed.');
}
