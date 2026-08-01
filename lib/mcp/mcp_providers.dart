import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers/providers.dart';
import 'mcp_approval_controller.dart';
import 'mcp_client_registry.dart';
import 'mcp_desktop_server.dart';
import 'mcp_server_factory.dart';
import 'notes_mcp_service.dart';
import 'desktop_lifecycle_service.dart';

final mcpClientRegistryProvider =
    ChangeNotifierProvider<McpClientRegistry>((ref) {
  return McpClientRegistry();
});

final mcpApprovalControllerProvider =
    ChangeNotifierProvider<McpApprovalController>((ref) {
  return McpApprovalController();
});

final notesMcpServiceProvider = Provider<NotesMcpService>((ref) {
  return NotesMcpService(
    notesRepository: ref.read(notesRepositoryProvider),
    registry: ref.read(mcpClientRegistryProvider),
    approvalController: ref.read(mcpApprovalControllerProvider),
    readSession: () => ref.read(vaultSessionProvider),
    onMutation: () {
      ref.invalidate(notesProvider);
      ref.invalidate(archivedNotesProvider);
    },
  );
});

final gitVaultMcpServerFactoryProvider =
    Provider<GitVaultMcpServerFactory>((ref) {
  const releaseVersion = String.fromEnvironment(
    'GITVAULT_VERSION',
    defaultValue: '1.0.0',
  );
  return GitVaultMcpServerFactory(
    registry: ref.read(mcpClientRegistryProvider),
    notesService: ref.read(notesMcpServiceProvider),
    version: releaseVersion,
  );
});

final mcpDesktopServerProvider =
    ChangeNotifierProvider<McpDesktopServer>((ref) {
  final server = McpDesktopServer(
    registry: ref.read(mcpClientRegistryProvider),
    approvalController: ref.read(mcpApprovalControllerProvider),
    serverFactory: ref.read(gitVaultMcpServerFactoryProvider),
    readSession: () => ref.read(vaultSessionProvider),
  );
  ref.listen(vaultSessionProvider, (previous, next) {
    server.handleSessionChanged(next);
  });
  return server;
});

final desktopLifecycleServiceProvider =
    Provider<DesktopLifecycleService>((ref) {
  final service = DesktopLifecycleService(
    registry: ref.read(mcpClientRegistryProvider),
    approvalController: ref.read(mcpApprovalControllerProvider),
    server: ref.read(mcpDesktopServerProvider),
    onLock: () {
      final notifier = ref.read(appLockSignalProvider.notifier);
      notifier.state = notifier.state + 1;
    },
  );
  ref.onDispose(service.dispose);
  return service;
});
