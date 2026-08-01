import 'package:flutter/foundation.dart';

import '../core/session/vault_session_controller.dart';
import 'mcp_approval_controller.dart';
import 'mcp_client_registry.dart';
import 'mcp_desktop_server_state.dart';
import 'mcp_server_factory.dart';

class McpDesktopServer extends ChangeNotifier {
  McpDesktopServer({
    required McpClientRegistry registry,
    required McpApprovalController approvalController,
    required GitVaultMcpServerFactory serverFactory,
    required VaultSessionState Function() readSession,
  });

  McpDesktopServerState get state => const McpDesktopServerState(
        status: McpDesktopServerStatus.unsupported,
      );

  bool get isSupported => false;

  Future<void> initialize() async {}

  Future<void> refresh() async {}

  Future<void> start() async {}

  Future<void> stop() async {}

  void handleSessionChanged(VaultSessionState session) {}

  Future<void> writeStdioProfile({
    required String clientId,
    required String token,
  }) async {}

  Future<void> removeStdioProfile(String clientId) async {}

  String stdioConfig(String clientId) => '';

  String httpConfig(String token) => '';
}
