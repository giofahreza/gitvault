import 'dart:async';
import 'dart:typed_data';
import 'package:dartssh2/dartssh2.dart';
import '../../../data/models/ssh_credential.dart';
import 'battery_optimization_manager.dart';

/// Manages persistent SSH connections with battery-aware keep-alive
class SshConnectionManager {
  final SshCredential credential;
  SSHClient? _client;
  SSHSession? _session;
  Timer? _keepAliveTimer;
  bool _isConnected = false;
  final BatteryOptimizationManager _batteryManager = BatteryOptimizationManager();

  late StreamSubscription<void> _doneSubscription;

  SshConnectionManager({required this.credential});

  bool get isConnected => _isConnected && _client != null;
  SSHSession? get session => _session;
  SSHClient? get client => _client;

  /// Connect to SSH server with automatic keep-alive
  Future<void> connect() async {
    if (_isConnected && _client != null) return;

    try {
      final socket = await SSHSocket.connect(
        credential.host,
        credential.port,
        timeout: const Duration(seconds: 10),
      );

      if (credential.authType == SshAuthType.password) {
        _client = SSHClient(
          socket,
          username: credential.username,
          onPasswordRequest: () => credential.password,
        );
      } else {
        _client = SSHClient(
          socket,
          username: credential.username,
          identities: [
            ...SSHKeyPair.fromPem(
              credential.privateKey,
              credential.passphrase.isNotEmpty ? credential.passphrase : null,
            ),
          ],
        );
      }

      _session = await _client!.shell(
        pty: SSHPtyConfig(
          type: 'xterm-256color',
          width: 80,
          height: 24,
        ),
        environment: {
          'LANG': 'en_US.UTF-8',
          'LC_ALL': 'en_US.UTF-8',
        },
      );

      _isConnected = true;

      // Listen for session close
      _doneSubscription = _session!.done.asStream().listen((_) {
        _isConnected = false;
        _keepAliveTimer?.cancel();
      });

      // Start keep-alive timer (send SSH_MSG_IGNORE every 30 seconds)
      _startKeepAlive();
    } catch (e) {
      _isConnected = false;
      rethrow;
    }
  }

  /// Start battery-aware keep-alive mechanism
  void _startKeepAlive() async {
    _keepAliveTimer?.cancel();

    // Get battery-optimized interval
    final shouldEnable = await _batteryManager.shouldEnableSshKeepAlive();
    if (!shouldEnable) {
      return; // Skip keep-alive on low battery
    }

    final intervalSeconds = await _batteryManager.getSshKeepAliveInterval();

    _keepAliveTimer = Timer.periodic(Duration(seconds: intervalSeconds), (_) async {
      if (_isConnected && _client != null) {
        // Re-check battery status periodically
        final canKeepAlive = await _batteryManager.shouldEnableSshKeepAlive();
        if (!canKeepAlive) {
          _keepAliveTimer?.cancel();
          return;
        }

        try {
          // Send SSH keep-alive by writing empty data
          _session?.write(Uint8List(0));
        } catch (e) {
          _isConnected = false;
        }
      }
    });
  }

  /// Disconnect and cleanup
  Future<void> disconnect() async {
    _keepAliveTimer?.cancel();
    _doneSubscription.cancel();
    _session?.close();
    _client?.close();
    _isConnected = false;
  }

  /// Reconnect if disconnected
  Future<void> ensureConnected() async {
    if (!_isConnected) {
      await connect();
    }
  }
}
