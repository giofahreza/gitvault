enum McpDesktopServerStatus {
  unsupported,
  stopped,
  starting,
  locked,
  ready,
  error,
}

class McpDesktopServerState {
  final McpDesktopServerStatus status;
  final Uri? endpoint;
  final String? error;
  final int activeSessions;

  const McpDesktopServerState({
    required this.status,
    this.endpoint,
    this.error,
    this.activeSessions = 0,
  });
}
