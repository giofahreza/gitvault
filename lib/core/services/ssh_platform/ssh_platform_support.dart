import 'ssh_platform_support_stub.dart'
    if (dart.library.io) 'ssh_platform_support_io.dart'
    if (dart.library.html) 'ssh_platform_support_web.dart';

/// Returns null when direct SSH transport is supported on current platform.
String? sshTransportUnsupportedReason() => sshTransportUnsupportedReasonImpl();

/// Throws [UnsupportedError] when direct SSH transport is not supported.
void ensureSshTransportSupported() {
  final reason = sshTransportUnsupportedReason();
  if (reason != null) {
    throw UnsupportedError(reason);
  }
}
