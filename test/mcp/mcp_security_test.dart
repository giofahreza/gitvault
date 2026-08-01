import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gitvault/core/session/vault_session_controller.dart';
import 'package:gitvault/mcp/mcp_approval_controller.dart';
import 'package:gitvault/mcp/mcp_client_registry.dart';
import 'package:gitvault/mcp/mcp_providers.dart';
import 'package:gitvault/mcp/mcp_models.dart';
import 'package:hive/hive.dart';

import 'test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory hiveDirectory;

  setUpAll(() async {
    hiveDirectory = await initializeTestHive();
  });

  setUp(resetMcpBoxes);

  tearDown(() async {
    await resetMcpBoxes();
  });

  tearDownAll(() async {
    await closeTestHive(hiveDirectory);
  });

  test('vault session exposes data only while unlocked', () {
    final controller = VaultSessionController();

    expect(controller.state.status, VaultSessionStatus.starting);
    expect(controller.state.canAccessVault, isFalse);

    controller.beginUnlock();
    expect(controller.state.status, VaultSessionStatus.unlocking);

    controller.unlock();
    expect(controller.state.canAccessVault, isTrue);

    controller.lock(reason: 'test');
    expect(controller.state.status, VaultSessionStatus.locked);
    expect(controller.state.canAccessVault, isFalse);

    controller.activateDuress();
    expect(controller.state.isTerminal, isTrue);
    expect(controller.state.canAccessVault, isFalse);

    controller.revoke();
    expect(controller.state.status, VaultSessionStatus.revoked);
    expect(controller.state.canAccessVault, isFalse);
  });

  test('credentials are hashed, rotated, and revoked', () async {
    final registry = McpClientRegistry();
    final issued = await registry.createClient(
      displayName: 'Test client',
      transport: McpClientTransport.streamableHttp,
      permissions: const {
        McpPermission.readMetadata,
        McpPermission.edit,
      },
      allowedTags: const {'#Work'},
      approvalExemptPermissions: const {
        McpPermission.edit,
        McpPermission.delete,
      },
    );
    await registry.setEnabled(true);

    expect(issued.client.tokenVerifier, isNot(contains(issued.token)));
    expect(issued.client.allowedTags, {'work'});
    expect(
      issued.client.approvalExemptPermissions,
      {McpPermission.edit},
    );
    expect(await registry.authenticateBearer(issued.token), isNotNull);

    final stored = Hive.box<String>(McpClientRegistry.settingsBoxName)
        .get('client:${issued.client.id}');
    expect(stored, isNotNull);
    expect(stored, isNot(contains(issued.token)));

    final rotated = await registry.rotateCredential(issued.client.id);
    expect(await registry.authenticateBearer(issued.token), isNull);
    expect(await registry.authenticateBearer(rotated.token), isNotNull);

    await registry.setEnabled(false);
    expect(await registry.authenticateBearer(rotated.token), isNull);
    await registry.setEnabled(true);

    await registry.revokeClient(issued.client.id);
    expect(await registry.authenticateBearer(rotated.token), isNull);
  });

  test('removing a permission removes its approval exemption', () async {
    final registry = McpClientRegistry();
    final issued = await registry.createClient(
      displayName: 'Editor',
      transport: McpClientTransport.stdio,
      permissions: const {McpPermission.edit},
      approvalExemptPermissions: const {McpPermission.edit},
    );

    await registry.updateClient(issued.client.id, permissions: const {});
    final updated = registry.getClient(issued.client.id)!;
    expect(updated.permissions, isEmpty);
    expect(updated.approvalExemptPermissions, isEmpty);
  });

  test('approval requests time out and lock cancellation resolves them',
      () async {
    final approvals = McpApprovalController();
    final timedOut = approvals.request(
      clientId: 'client',
      clientName: 'Client',
      permission: McpPermission.edit,
      action: 'update_note',
      summary: 'Edit note',
      timeout: const Duration(milliseconds: 20),
    );
    expect(await timedOut, McpApprovalDecision.timeout);

    final cancelled = approvals.request(
      clientId: 'client',
      clientName: 'Client',
      permission: McpPermission.create,
      action: 'create_note',
      summary: 'Create note',
    );
    approvals.cancelAll();
    expect(await cancelled, McpApprovalDecision.cancelled);
    expect(approvals.pending, isEmpty);
    approvals.dispose();
  });

  test('MCP runtime providers stay stable when registry settings change',
      () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final registry = container.read(mcpClientRegistryProvider);
    final server = container.read(mcpDesktopServerProvider);
    final lifecycle = container.read(desktopLifecycleServiceProvider);

    await registry.setEnabled(true);
    await registry.setKeepInTray(false);

    expect(container.read(mcpDesktopServerProvider), same(server));
    expect(container.read(desktopLifecycleServiceProvider), same(lifecycle));
  });
}
