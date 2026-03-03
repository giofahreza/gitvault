String? sshTransportUnsupportedReasonImpl() {
  return 'Direct SSH from web browser is not supported (no raw TCP sockets). '
      'Use Android app, or provide an SSH-over-WebSocket proxy.';
}
