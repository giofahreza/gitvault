import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitvault/mcp/mcp_client_registry.dart';
import 'package:gitvault/mcp/mcp_models.dart';
import 'package:hive/hive.dart';

import 'test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late McpClientRegistry registry;
  late McpIssuedCredential issued;
  setUpAll(() async => directory = await initializeTestHive());
  setUp(() async {
    await resetMcpBoxes();
    registry = McpClientRegistry();
    await registry.setEnabled(true);
    issued = await registry.createClient(
        displayName: 'Disk test',
        transport: McpClientTransport.streamableHttp,
        permissions: {McpPermission.readMetadata});
  });
  tearDown(() async {
    registry.dispose();
    await resetMcpBoxes();
  });
  tearDownAll(() => closeTestHive(directory));

  for (final action in [
    'create',
    'grant',
    'scope',
    'policy',
    'rotate',
    'revoke',
    'restore',
    'revoke-all',
    'exemption',
    'touch',
    'remove',
    'disable',
    'port',
    'startup',
    'tray',
  ]) {
    test('MCP-GAP-003 failed durable $action never publishes or authorizes',
        () async {
      if (action == 'restore') await registry.revokeClient(issued.client.id);
      final original = registry.clients.map((c) => c.toJson()).toList();
      await Hive.box<String>(McpClientRegistry.settingsBoxName).close();
      Future<dynamic> operation() => switch (action) {
            'create' => registry.createClient(
                displayName: 'Must not appear',
                transport: McpClientTransport.stdio,
                permissions: {McpPermission.create}),
            'grant' => registry.updateClient(issued.client.id,
                permissions: McpPermission.values.toSet()),
            'scope' =>
              registry.updateClient(issued.client.id, allowedTags: {'secret'}),
            'policy' => registry.updateClient(issued.client.id,
                writePolicy: McpWritePolicy.allowWhileUnlocked),
            'rotate' => registry.rotateCredential(issued.client.id),
            'revoke' => registry.revokeClient(issued.client.id),
            'restore' => registry.restoreClient(issued.client.id),
            'revoke-all' => registry.revokeAllClients(),
            'exemption' => registry.allowWriteWithoutApproval(
                issued.client.id, McpPermission.create),
            'touch' => registry.touchClient(issued.client.id),
            'remove' => registry.removeClient(issued.client.id),
            'port' => registry.setPort(39472),
            'startup' => registry.setLaunchAtStartup(true),
            'tray' => registry.setKeepInTray(false),
            _ => registry.setEnabled(false),
          };
      await expectLater(operation(), throwsA(isA<HiveError>()));
      expect(registry.clients.map((c) => c.toJson()).toList(), original);
      expect(registry.port, McpClientRegistry.defaultPort);
      expect(registry.launchAtStartup, false);
      expect(registry.keepInTray, true);
      expect(registry.enabled, false,
          reason: 'Storage failure must disable access until a fresh reload');
      expect(await registry.authenticateBearer(issued.token), null);
      // The failed action must not pretend to be durable after a fresh reload.
      final reloaded = McpClientRegistry();
      await reloaded.initialize();
      expect(reloaded.clients.map((c) => c.toJson()).toList(), original);
      reloaded.dispose();
    });
  }

  test('MCP-GAP-003 authentication storage failure rejects without throwing',
      () async {
    await Hive.box<String>(McpClientRegistry.settingsBoxName).close();
    expect(await registry.authenticateBearer(issued.token), null);
    expect(registry.enabled, false);
    expect(registry.getClient(issued.client.id)!.lastUsedAt, null);
  });

  test('MCP-GAP-003 simultaneous permission and scope changes both persist',
      () async {
    await Future.wait([
      registry.updateClient(issued.client.id,
          permissions: {McpPermission.readContent}),
      registry.updateClient(issued.client.id, deniedTags: {'private'}),
    ]);
    final client = registry.getClient(issued.client.id)!;
    expect(client.permissions, {McpPermission.readContent});
    expect(client.deniedTags, {'private'});
    final reloaded = McpClientRegistry();
    await reloaded.initialize();
    expect(reloaded.getClient(issued.client.id)!.toJson(), client.toJson());
    reloaded.dispose();
  });

  test(
      'MCP-GAP-003 queued rotation invalidates authentication already awaiting touch',
      () async {
    final rotation = registry.rotateCredential(issued.client.id);
    final oldAuthentication = registry.authenticateBearer(issued.token);
    final replacement = await rotation;
    expect(await oldAuthentication, null);
    expect((await registry.authenticateBearer(replacement.token))?.id,
        issued.client.id);
  });

  test(
      'MCP-GAP-003 invalid mutation does not disable access or poison its queue',
      () async {
    await expectLater(
        registry.setPort(0), throwsA(isA<McpOperationException>()));
    expect(registry.enabled, true);
    await registry.updateClient(issued.client.id,
        displayName: 'Recovered queue');
    expect((await registry.authenticateBearer(issued.token))?.displayName,
        'Recovered queue');
  });
}
