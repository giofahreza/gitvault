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
import 'package:hive/hive.dart';

import 'test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late McpClientRegistry registry;
  late McpApprovalController approvals;
  late McpDesktopServer server;
  late Uri endpoint;
  setUpAll(() async {
    HttpOverrides.global = null;
    directory = await initializeTestHive();
    silenceMcpLogs();
  });
  setUp(() async {
    await resetMcpBoxes();
    registry = McpClientRegistry();
    approvals = McpApprovalController();
    final session = VaultSessionState(
        status: VaultSessionStatus.unlocked,
        changedAt: DateTime.now(),
        generation: 1);
    server = McpDesktopServer(
        registry: registry,
        approvalController: approvals,
        serverFactory: GitVaultMcpServerFactory(
            registry: registry,
            version: 'test',
            notesService: NotesMcpService(
                notesRepository: MemoryNotesRepository([]),
                registry: registry,
                approvalController: approvals,
                readSession: () => session)),
        readSession: () => session);
    await registry.setEnabled(true);
    await server.initialize();
    endpoint = server.state.endpoint!;
  });
  tearDown(() async {
    await server.stop();
    server.dispose();
    approvals.dispose();
    registry.dispose();
    await resetMcpBoxes();
  });
  tearDownAll(() => closeTestHive(directory));
  Future<String> credential() async => (await registry.createClient(
          displayName: 'Boundary client',
          transport: McpClientTransport.streamableHttp,
          permissions: {McpPermission.readMetadata}))
      .token;
  Map<String, String> headers(String token,
          {String? version, String? sessionId}) =>
      {
        'authorization': 'Bearer $token',
        'content-type': 'application/json',
        'accept': 'application/json, text/event-stream',
        if (version != null) 'mcp-protocol-version': version,
        if (sessionId != null) 'mcp-session-id': sessionId,
      };
  Map<String, dynamic> responseJson(http.Response response) {
    if (response.body.startsWith('event:') ||
        response.body.startsWith('data:')) {
      return jsonDecode(const LineSplitter()
          .convert(response.body)
          .firstWhere((line) => line.startsWith('data:'))
          .substring(5)) as Map<String, dynamic>;
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  test('MCP-GAP-003 HTTP storage failure terminates authentication safely',
      () async {
    final token = await credential();
    await Hive.box<String>(McpClientRegistry.settingsBoxName).close();
    try {
      final response = await http.get(endpoint, headers: {
        'authorization': 'Bearer $token'
      }).timeout(const Duration(seconds: 5));
      expect(response.statusCode, HttpStatus.unauthorized);
      expect(response.body, isNot(contains(token)));
    } on http.ClientException {
      // The registry listener may close the listener before 401 is delivered.
      // Either a bounded rejection or a closed connection is fail-closed.
    } on SocketException {
      // Listener shutdown may race the in-flight response on this OS.
    }
    expect(registry.enabled, false);
    expect(await registry.authenticateBearer(token), null);
  });

  test('MCP-GAP-001 dated HTTP versions, fallback and unsupported headers',
      () async {
    final token = await credential();
    for (final version in legacyProtocolVersions) {
      final initialized = await http.post(endpoint,
          headers: headers(token, version: version),
          body: jsonEncode({
            'jsonrpc': '2.0',
            'id': 1,
            'method': 'initialize',
            'params': {
              'protocolVersion': version,
              'capabilities': {},
              'clientInfo': {'name': 'dated-client', 'version': '1'}
            }
          }));
      expect(initialized.statusCode, 200, reason: version);
      expect(responseJson(initialized)['result']['protocolVersion'], version);
      final sessionId = initialized.headers['mcp-session-id'];
      expect(sessionId, isNotNull);
      final notification = await http.post(endpoint,
          headers: headers(token, version: version, sessionId: sessionId),
          body: jsonEncode(
              {'jsonrpc': '2.0', 'method': 'notifications/initialized'}));
      expect(notification.statusCode, 202);
      final listed = await http.post(endpoint,
          headers: headers(token, version: version, sessionId: sessionId),
          body: jsonEncode({
            'jsonrpc': '2.0',
            'id': 2,
            'method': 'tools/call',
            'params': {'name': 'list_notes', 'arguments': {}}
          }));
      expect(listed.statusCode, 200, reason: version);
      expect(responseJson(listed)['result']['isError'], isNot(true));
      expect(responseJson(listed)['result']['content'], isNotEmpty);
      for (final unsupported in [
        '1900-01-01',
        '2099-12-31',
        'invalid-version'
      ]) {
        final response = await http.post(endpoint,
            headers: headers(token, version: unsupported, sessionId: sessionId),
            body: '{"jsonrpc":"2.0","id":3,"method":"tools/list"}');
        expect(response.statusCode, 400);
        expect(responseJson(response)['error']['message'],
            'Unsupported protocol version');
      }
      final removed = await http.delete(endpoint,
          headers: headers(token, version: version, sessionId: sessionId));
      expect(removed.statusCode, 200);
    }
    final stateless = await http.post(endpoint,
        headers: {
          ...headers(token, version: stableProtocolVersion),
          'mcp-method': 'tools/list'
        },
        body: jsonEncode({
          'jsonrpc': '2.0',
          'id': 4,
          'method': 'tools/list',
          'params': {
            '_meta': buildProtocolRequestMeta(
                protocolVersion: stableProtocolVersion,
                clientInfo: const Implementation(
                    name: 'stateless-client', version: '1'),
                clientCapabilities: const ClientCapabilities())
          }
        }));
    expect(stateless.statusCode, 200, reason: stateless.body);
    expect(responseJson(stateless)['result']['tools'], isNotEmpty);
    expect(stateless.headers['mcp-session-id'], null);
    final fallback = await http.post(endpoint,
        headers: headers(token),
        body: jsonEncode({
          'jsonrpc': '2.0',
          'id': 5,
          'method': 'initialize',
          'params': {
            'protocolVersion': '1900-01-01',
            'capabilities': {},
            'clientInfo': {'name': 'fallback', 'version': '1'}
          }
        }));
    expect(fallback.statusCode, 200);
    expect(responseJson(fallback)['result']['protocolVersion'],
        latestInitializationProtocolVersion);
  });

  test(
      'MCP-GAP-011 concurrent flood is isolated and recovers after rate window',
      () async {
    final token = await credential();
    final independent = await credential();
    final client = http.Client();
    addTearDown(client.close);
    Future<http.Response> request(String bearer) => client
        .get(endpoint, headers: {'authorization': 'Bearer $bearer'}).timeout(
            const Duration(seconds: 10));
    // A thousand actual requests, 25 in flight, including the accepted window.
    final statuses = <int>[];
    for (var offset = 0; offset < 1000; offset += 25) {
      statuses.addAll(
          (await Future.wait(List.generate(25, (_) => request(token))))
              .map((response) => response.statusCode));
    }
    expect(statuses.where((status) => status == 400), hasLength(120));
    expect(statuses.where((status) => status == 429), hasLength(880));
    expect((await request(independent)).statusCode, 400);
    // Exercise the real wall-clock window without adding a production clock hook.
    await Future<void>.delayed(const Duration(seconds: 61));
    final recovered =
        await Future.wait(List.generate(120, (_) => request(token)));
    expect(recovered.every((response) => response.statusCode == 400), true);
    expect((await request(token)).statusCode, 429);
    expect((await request(independent)).statusCode, 400);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
