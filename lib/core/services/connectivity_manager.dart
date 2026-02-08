import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// Manages network connectivity and monitoring
/// Provides connectivity status and change notifications
class ConnectivityManager {
  final Connectivity _connectivity = Connectivity();

  StreamSubscription<List<ConnectivityResult>>? _subscription;
  final _connectivityController = StreamController<ConnectivityStatus>.broadcast();

  /// Stream of connectivity status changes
  Stream<ConnectivityStatus> get connectivityStream => _connectivityController.stream;

  /// Start monitoring connectivity changes
  void startMonitoring() {
    _subscription = _connectivity.onConnectivityChanged.listen(
      (List<ConnectivityResult> results) {
        final status = _mapConnectivityResult(results);
        debugPrint('[ConnectivityManager] Status changed: $status');
        _connectivityController.add(status);
      },
      onError: (error) {
        debugPrint('[ConnectivityManager] Error: $error');
      },
    );
  }

  /// Stop monitoring connectivity changes
  void stopMonitoring() {
    _subscription?.cancel();
    _subscription = null;
  }

  /// Get current connectivity status
  Future<ConnectivityStatus> getConnectivityStatus() async {
    try {
      final results = await _connectivity.checkConnectivity();
      return _mapConnectivityResult(results);
    } catch (e) {
      debugPrint('[ConnectivityManager] Error checking connectivity: $e');
      return ConnectivityStatus(
        isConnected: false,
        connectionType: ConnectionType.none,
        isMetered: true,
      );
    }
  }

  /// Check if device has internet connection
  Future<bool> hasInternetConnection() async {
    final status = await getConnectivityStatus();
    return status.isConnected;
  }

  /// Check if connected to WiFi
  Future<bool> isConnectedToWifi() async {
    final status = await getConnectivityStatus();
    return status.connectionType == ConnectionType.wifi;
  }

  /// Check if connection is metered (cellular data)
  Future<bool> isMeteredConnection() async {
    final status = await getConnectivityStatus();
    return status.isMetered;
  }

  /// Wait for internet connection (with timeout)
  Future<bool> waitForConnection({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final completer = Completer<bool>();

    // Check immediately
    if (await hasInternetConnection()) {
      return true;
    }

    // Wait for connection change
    late StreamSubscription<ConnectivityStatus> subscription;
    subscription = connectivityStream.listen((status) {
      if (status.isConnected && !completer.isCompleted) {
        completer.complete(true);
        subscription.cancel();
      }
    });

    // Start monitoring if not already
    if (_subscription == null) {
      startMonitoring();
    }

    // Return with timeout
    return Future.any([
      completer.future,
      Future.delayed(timeout, () => false),
    ]).then((result) {
      subscription.cancel();
      return result;
    });
  }

  /// Map ConnectivityResult to ConnectivityStatus
  ConnectivityStatus _mapConnectivityResult(List<ConnectivityResult> results) {
    if (results.isEmpty || results.contains(ConnectivityResult.none)) {
      return ConnectivityStatus(
        isConnected: false,
        connectionType: ConnectionType.none,
        isMetered: true,
      );
    }

    // Priority: WiFi > Ethernet > Mobile
    if (results.contains(ConnectivityResult.wifi)) {
      return ConnectivityStatus(
        isConnected: true,
        connectionType: ConnectionType.wifi,
        isMetered: false,
      );
    } else if (results.contains(ConnectivityResult.ethernet)) {
      return ConnectivityStatus(
        isConnected: true,
        connectionType: ConnectionType.ethernet,
        isMetered: false,
      );
    } else if (results.contains(ConnectivityResult.mobile)) {
      return ConnectivityStatus(
        isConnected: true,
        connectionType: ConnectionType.cellular,
        isMetered: true,
      );
    } else if (results.contains(ConnectivityResult.vpn)) {
      return ConnectivityStatus(
        isConnected: true,
        connectionType: ConnectionType.vpn,
        isMetered: false,
      );
    }

    return ConnectivityStatus(
      isConnected: false,
      connectionType: ConnectionType.none,
      isMetered: true,
    );
  }

  /// Clean up resources
  void dispose() {
    stopMonitoring();
    _connectivityController.close();
  }
}

/// Connectivity status
class ConnectivityStatus {
  final bool isConnected;
  final ConnectionType connectionType;
  final bool isMetered;

  ConnectivityStatus({
    required this.isConnected,
    required this.connectionType,
    required this.isMetered,
  });

  bool get isWifi => connectionType == ConnectionType.wifi;
  bool get isCellular => connectionType == ConnectionType.cellular;
  bool get isEthernet => connectionType == ConnectionType.ethernet;

  @override
  String toString() {
    return 'ConnectivityStatus(connected: $isConnected, type: $connectionType, metered: $isMetered)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ConnectivityStatus &&
        other.isConnected == isConnected &&
        other.connectionType == connectionType &&
        other.isMetered == isMetered;
  }

  @override
  int get hashCode => Object.hash(isConnected, connectionType, isMetered);
}

/// Connection types
enum ConnectionType {
  wifi,
  cellular,
  ethernet,
  vpn,
  none,
}
