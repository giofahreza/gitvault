import 'mcp_approval_controller.dart';
import 'mcp_client_registry.dart';
import 'mcp_desktop_server.dart';

class DesktopLifecycleService {
  DesktopLifecycleService({
    required McpClientRegistry registry,
    required McpApprovalController approvalController,
    required McpDesktopServer server,
    required void Function() onLock,
    required void Function() onQuit,
  });

  Future<void> initialize() async {}

  Future<void> showWindow() async {}

  Future<void> requestQuit() async {}

  void dispose() {}
}
