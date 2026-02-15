import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';

/// Manages battery-aware operations and optimization
/// Adapts sync behavior based on battery status
class BatteryOptimizationManager {
  final Battery _battery = Battery();

  // Battery thresholds
  static const int _lowBatteryThreshold = 20;
  static const int _mediumBatteryThreshold = 50;
  static const int _criticalBatteryThreshold = 10;

  /// Get current battery level (0-100)
  Future<int> getBatteryLevel() async {
    try {
      return await _battery.batteryLevel;
    } catch (e) {
      debugPrint('[BatteryManager] Error getting battery level: $e');
      return 100; // Assume full battery on error
    }
  }

  /// Check if device is charging
  Future<bool> isCharging() async {
    try {
      final state = await _battery.batteryState;
      return state == BatteryState.charging || state == BatteryState.full;
    } catch (e) {
      debugPrint('[BatteryManager] Error checking charging state: $e');
      return false;
    }
  }

  /// Check if battery is in low power mode
  Future<bool> isInLowPowerMode() async {
    try {
      final state = await _battery.batteryState;
      return state == BatteryState.connectedNotCharging;
    } catch (e) {
      debugPrint('[BatteryManager] Error checking power mode: $e');
      return false;
    }
  }

  /// Determine if sync should be performed based on battery status
  Future<bool> shouldPerformSync() async {
    final batteryLevel = await getBatteryLevel();
    final charging = await isCharging();

    // Always sync when charging
    if (charging) {
      return true;
    }

    // Never sync on critical battery
    if (batteryLevel < _criticalBatteryThreshold) {
      debugPrint('[BatteryManager] Critical battery level ($batteryLevel%), skipping sync');
      return false;
    }

    // Sync normally above threshold
    return batteryLevel > _lowBatteryThreshold;
  }

  /// Get recommended sync interval based on battery level
  /// Returns interval in minutes
  Future<int> getRecommendedSyncInterval({
    int defaultInterval = 60,
  }) async {
    final batteryLevel = await getBatteryLevel();
    final charging = await isCharging();

    if (charging) {
      // More frequent when charging
      return 15;
    } else if (batteryLevel > _mediumBatteryThreshold) {
      // Normal interval
      return defaultInterval;
    } else if (batteryLevel > _lowBatteryThreshold) {
      // Less frequent on medium battery
      return defaultInterval * 2;
    } else {
      // Minimal sync on low battery
      return defaultInterval * 4;
    }
  }

  /// Get battery optimization status
  Future<BatteryOptimizationStatus> getOptimizationStatus() async {
    final level = await getBatteryLevel();
    final charging = await isCharging();
    final lowPowerMode = await isInLowPowerMode();

    return BatteryOptimizationStatus(
      batteryLevel: level,
      isCharging: charging,
      isInLowPowerMode: lowPowerMode,
      shouldOptimize: level < _mediumBatteryThreshold && !charging,
      recommendedInterval: await getRecommendedSyncInterval(),
    );
  }

  /// Listen to battery state changes
  Stream<BatteryState> get batteryStateStream => _battery.onBatteryStateChanged;

  /// Calculate power consumption score (0-100)
  /// Higher score = more power consumption allowed
  Future<int> getPowerConsumptionScore() async {
    final level = await getBatteryLevel();
    final charging = await isCharging();

    if (charging) {
      return 100; // No restrictions when charging
    } else if (level > 80) {
      return 80;
    } else if (level > 50) {
      return 60;
    } else if (level > 20) {
      return 40;
    } else {
      return 20; // Severely restrict when low
    }
  }

  /// Determine if SSH keep-alive should be active
  Future<bool> shouldEnableSshKeepAlive() async {
    final batteryLevel = await getBatteryLevel();
    final charging = await isCharging();

    // Always enable when charging
    if (charging) {
      return true;
    }

    // Disable keep-alive on low battery to save power
    return batteryLevel > _lowBatteryThreshold;
  }

  /// Get adaptive keep-alive interval for SSH
  /// Returns interval in seconds
  Future<int> getSshKeepAliveInterval() async {
    final batteryLevel = await getBatteryLevel();
    final charging = await isCharging();

    if (charging) {
      return 15; // 15 seconds when charging
    } else if (batteryLevel > _mediumBatteryThreshold) {
      return 30; // 30 seconds on good battery
    } else if (batteryLevel > _lowBatteryThreshold) {
      return 60; // 1 minute on medium battery
    } else {
      return 300; // 5 minutes on low battery
    }
  }
}

/// Battery optimization status
class BatteryOptimizationStatus {
  final int batteryLevel;
  final bool isCharging;
  final bool isInLowPowerMode;
  final bool shouldOptimize;
  final int recommendedInterval;

  BatteryOptimizationStatus({
    required this.batteryLevel,
    required this.isCharging,
    required this.isInLowPowerMode,
    required this.shouldOptimize,
    required this.recommendedInterval,
  });

  bool get isHealthy => batteryLevel > 20 || isCharging;
  bool get isCritical => batteryLevel < 10 && !isCharging;

  @override
  String toString() {
    return 'BatteryStatus(level: $batteryLevel%, charging: $isCharging, '
        'optimize: $shouldOptimize, interval: ${recommendedInterval}min)';
  }
}
