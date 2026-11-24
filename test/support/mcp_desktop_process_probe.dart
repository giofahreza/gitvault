import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:gitvault/core/session/vault_session_controller.dart';
import 'package:gitvault/mcp/mcp_approval_controller.dart';
import 'package:gitvault/mcp/mcp_client_registry.dart';
import 'package:gitvault/mcp/mcp_desktop_server.dart';
import 'package:gitvault/mcp/mcp_desktop_server_state.dart';
import 'package:gitvault/mcp/mcp_models.dart';
import 'package:gitvault/mcp/mcp_paths_io.dart';
import 'package:gitvault/mcp/mcp_server_factory.dart';
import 'package:gitvault/mcp/notes_mcp_service.dart';
import 'package:hive/hive.dart';
import 'package:mcp_dart/mcp_dart.dart';

import '../mcp/test_support.dart';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final environment = Platform.environment;
  final action = environment['GITVAULT_DESKTOP_ACTION']!;
  Hive.init(environment['GITVAULT_DESKTOP_HIVE']!);
  final registry = McpClientRegistry();
  await registry.initialize();
  final approvals = McpApprovalController();
  final session = VaultSessionState(
      status: VaultSessionStatus.unlocked,
      changedAt: DateTime.now(),
      generation: 1);
  final notes = NotesMcpService(
      notesRepository: MemoryNotesRepository([
        testNote(id: 'visible', title: 'Visible note', content: 'probe-body'),
      ]),
      registry: registry,
      approvalController: approvals,
      readSession: () => session);
  final server = McpDesktopServer(
      registry: registry,
      approvalController: approvals,
      serverFactory: GitVaultMcpServerFactory(
          registry: registry, notesService: notes, version: 'probe'),
      readSession: () => session);

  Future<int> status(Uri endpoint, String token) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(endpoint);
      request.headers.set('authorization', 'Bearer $token');
      request.headers.contentType = ContentType.json;
      request.write('{}');
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode;
    } finally {
      client.close(force: true);
    }
  }

  Future<McpClient> connectBridge(String id) async {
    final client = McpClient(
        const Implementation(name: 'process-probe', version: '1'),
        options: const McpClientOptions(protocol: McpProtocol.stable));
    try {
      await client.connect(StdioClientTransport(StdioServerParameters(
          command: environment['GITVAULT_DESKTOP_DART']!,
          args: ['run', 'bin/gitvault_mcp.dart', '--profile', id],
          environment: environment,
          workingDirectory: Directory.current.path)));
      return client;
    } catch (_) {
      await client.close();
      rethrow;
    }
  }

  try {
    await McpLocalPaths.ensureDirectories();
    if (action == 'restart') {
      // The previous process was killed without closing Hive or deleting its
      // discovery file. The parent holds the original port to force fallback.
      final issued = registry.activeClients.single;
      final oldDiscovery =
          jsonDecode(await McpLocalPaths.discoveryFile().readAsString()) as Map;
      await server.initialize();
      final newDiscovery =
          jsonDecode(await McpLocalPaths.discoveryFile().readAsString()) as Map;
      check(newDiscovery['endpoint'] != oldDiscovery['endpoint'],
          'Restart did not replace the stale port');
      check(newDiscovery['pid'] == pid, 'Restart left the previous PID');
      final bridge = await connectBridge(issued.id);
      try {
        final result = await bridge.callTool(const CallToolRequest(
            name: 'get_note', arguments: {'note_id': 'visible'}));
        check(
            !result.isError &&
                (result.structuredContent!['note'] as Map)['content'] ==
                    'probe-body',
            'Restarted bridge could not read a note');
      } finally {
        await bridge.close();
      }
    } else {
      final portReservation =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      await registry.setPort(portReservation.port);
      await portReservation.close();
      await registry.setEnabled(true);
      final issued = await registry.createClient(
          displayName: 'Process client',
          transport: McpClientTransport.stdio,
          permissions: {McpPermission.readMetadata, McpPermission.readContent});
      if (action == 'discovery-failure') {
        final file = McpLocalPaths.discoveryFile();
        final obstruction = await Directory(file.path).create();
        await server.initialize();
        check(server.state.status == McpDesktopServerStatus.error,
            'Unwritable discovery must report startup failure');
        Socket? orphan;
        try {
          orphan = await Socket.connect(
              InternetAddress.loopbackIPv4, registry.port,
              timeout: const Duration(seconds: 1));
        } on SocketException {
          // Expected: a failed start must release its listener.
        }
        orphan?.destroy();
        check(
            orphan == null, 'Discovery failure leaked an orphan HTTP listener');
        await obstruction.delete();
        await server.start();
        check(server.state.endpoint?.port == registry.port,
            'Retry could not reuse the released port');
      } else {
        await server.initialize();
        await server.writeStdioProfile(
            clientId: issued.client.id, token: issued.token);
        final endpoint = server.state.endpoint!;
        final bridge = await connectBridge(issued.client.id);
        check((await bridge.listTools()).tools.isNotEmpty,
            'The production bridge could not list tools');
        if (action == 'crash') {
          await Hive.box<String>(McpClientRegistry.settingsBoxName).flush();
          stdout.writeln(
              'READY:${jsonEncode({'endpoint': endpoint.toString()})}');
          await Completer<void>().future;
        }
        await bridge.close();
        final rotated = await registry.rotateCredential(issued.client.id);
        final profile = McpLocalPaths.profileFile(issued.client.id);
        await profile.delete();
        final obstruction = await Directory(profile.path).create();
        var failed = false;
        try {
          await server.writeStdioProfile(
              clientId: issued.client.id, token: rotated.token);
        } on FileSystemException {
          failed = true;
        }
        check(failed, 'Profile persistence failure was hidden');
        check(await status(endpoint, issued.token) == 401,
            'Failed profile write revived the old credential');
        check(await status(endpoint, rotated.token) != 401,
            'Rotated credential failed direct authentication');
        await obstruction.delete();
        // A syntactically valid stale file must not authenticate after rotation.
        await server.writeStdioProfile(
            clientId: issued.client.id, token: issued.token);
        var staleRejected = false;
        try {
          final stale = await connectBridge(issued.client.id);
          await stale.close();
        } catch (_) {
          staleRejected = true;
        }
        check(staleRejected, 'A stale profile authenticated after rotation');
        await server.writeStdioProfile(
            clientId: issued.client.id, token: rotated.token);
        final replacement = await connectBridge(issued.client.id);
        check((await replacement.listTools()).tools.isNotEmpty,
            'Profile retry did not recover');
        await registry.revokeClient(issued.client.id);
        check(await status(endpoint, rotated.token) == 401,
            'Revocation left the current token active');
        await replacement.close();
        await server.removeStdioProfile(issued.client.id);
        check(!await profile.exists(), 'Revocation left the profile file');
      }
    }
    await server.stop();
    check(!await McpLocalPaths.discoveryFile().exists(),
        'Stop left discovery data');
    stdout.writeln('VERIFIED:$action');
  } catch (error, stack) {
    stderr.writeln('$error\n$stack');
    exitCode = 1;
  } finally {
    await server.stop();
    server.dispose();
    approvals.dispose();
    registry.dispose();
    await Hive.close();
  }
  // A probe deliberately treats leaked OS handles as a failed assertion above;
  // exit also bounds any failing regression run that leaves such a handle open.
  exit(exitCode);
}
