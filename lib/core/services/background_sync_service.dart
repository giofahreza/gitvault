import 'dart:async';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:workmanager/workmanager.dart';
import '../../data/repositories/sync_engine.dart';
import '../../data/repositories/vault_repository.dart';
import '../../data/repositories/notes_repository.dart';
import '../../data/repositories/ssh_repository.dart';
import '../crypto/crypto_manager.dart';
import '../crypto/key_storage.dart';
import 'github_service.dart';
import 'battery_optimization_manager.dart';
import 'connectivity_manager.dart';

/// Background sync service using WorkManager
/// Implements battery-efficient periodic sync with adaptive intervals
class BackgroundSyncService {
  static const String _taskName = 'gitvault_background_sync';
  static const String _settingsBoxName = 'background_sync_settings';

  // Sync intervals (in minutes)
  static const int _defaultInterval = 60; // 1 hour
  static const int _minInterval = 15; // 15 minutes
  static const int _maxInterval = 360; // 6 hours

  static Box<String>? _settingsBox;

  /// Initialize background sync service
  static Future<void> initialize() async {
    _settingsBox = await Hive.openBox<String>(_settingsBoxName);

    // Initialize WorkManager
    await Workmanager().initialize(
      callbackDispatcher,
      isInDebugMode: kDebugMode,
    );
  }

  /// Enable background sync with specified interval
  static Future<void> enableBackgroundSync({
    int intervalMinutes = _defaultInterval,
    bool requireWifi = true,
    bool requireCharging = false,
  }) async {
    if (_settingsBox == null) await initialize();

    // Store settings
    await _settingsBox!.put('enabled', 'true');
    await _settingsBox!.put('interval', intervalMinutes.toString());
    await _settingsBox!.put('require_wifi', requireWifi.toString());
    await _settingsBox!.put('require_charging', requireCharging.toString());

    // Schedule periodic sync
    await Workmanager().registerPeriodicTask(
      _taskName,
      _taskName,
      frequency: Duration(minutes: intervalMinutes.clamp(_minInterval, _maxInterval)),
      constraints: Constraints(
        networkType: requireWifi ? NetworkType.unmetered : NetworkType.connected,
        requiresBatteryNotLow: true,
        requiresCharging: requireCharging,
        requiresDeviceIdle: false,
        requiresStorageNotLow: true,
      ),
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: const Duration(minutes: 15),
      existingWorkPolicy: ExistingWorkPolicy.replace,
    );
  }

  /// Disable background sync
  static Future<void> disableBackgroundSync() async {
    if (_settingsBox == null) await initialize();

    await _settingsBox!.put('enabled', 'false');
    await Workmanager().cancelByUniqueName(_taskName);
  }

  /// Check if background sync is enabled
  static Future<bool> isEnabled() async {
    if (_settingsBox == null) await initialize();
    return _settingsBox!.get('enabled') == 'true';
  }

  /// Get current sync interval
  static Future<int> getSyncInterval() async {
    if (_settingsBox == null) await initialize();
    final intervalStr = _settingsBox!.get('interval');
    return intervalStr != null ? int.parse(intervalStr) : _defaultInterval;
  }

  /// Trigger immediate sync (one-time)
  static Future<void> triggerImmediateSync() async {
    await Workmanager().registerOneOffTask(
      'immediate_sync',
      _taskName,
      constraints: Constraints(
        networkType: NetworkType.connected,
      ),
      existingWorkPolicy: ExistingWorkPolicy.replace,
    );
  }

  /// Update sync interval based on battery level (adaptive sync)
  static Future<void> updateAdaptiveInterval() async {
    final batteryManager = BatteryOptimizationManager();
    final batteryLevel = await batteryManager.getBatteryLevel();
    final isCharging = await batteryManager.isCharging();

    int newInterval;
    if (isCharging) {
      // More frequent when charging
      newInterval = _minInterval;
    } else if (batteryLevel > 50) {
      // Normal interval
      newInterval = _defaultInterval;
    } else if (batteryLevel > 20) {
      // Less frequent on medium battery
      newInterval = _defaultInterval * 2;
    } else {
      // Minimal sync on low battery
      newInterval = _maxInterval;
    }

    final currentInterval = await getSyncInterval();
    if (currentInterval != newInterval) {
      final requireWifi = _settingsBox!.get('require_wifi') == 'true';
      final requireCharging = _settingsBox!.get('require_charging') == 'true';

      await enableBackgroundSync(
        intervalMinutes: newInterval,
        requireWifi: requireWifi,
        requireCharging: requireCharging,
      );
    }
  }

  /// Record sync result
  static Future<void> _recordSyncResult({
    required bool success,
    String? error,
  }) async {
    if (_settingsBox == null) return;

    await _settingsBox!.put('last_sync', DateTime.now().toIso8601String());
    await _settingsBox!.put('last_sync_success', success.toString());
    if (error != null) {
      await _settingsBox!.put('last_sync_error', error);
    }

    // Update consecutive failures
    final failures = _settingsBox!.get('consecutive_failures') ?? '0';
    final failureCount = int.parse(failures);

    if (success) {
      await _settingsBox!.put('consecutive_failures', '0');
    } else {
      await _settingsBox!.put('consecutive_failures', (failureCount + 1).toString());

      // If too many failures, increase interval
      if (failureCount > 3) {
        await updateAdaptiveInterval();
      }
    }
  }

  /// Get last sync time
  static Future<DateTime?> getLastSyncTime() async {
    if (_settingsBox == null) await initialize();
    final timestamp = _settingsBox!.get('last_sync');
    return timestamp != null ? DateTime.parse(timestamp) : null;
  }

  /// Get sync statistics
  static Future<Map<String, dynamic>> getSyncStats() async {
    if (_settingsBox == null) await initialize();

    return {
      'enabled': await isEnabled(),
      'interval': await getSyncInterval(),
      'last_sync': await getLastSyncTime(),
      'last_success': _settingsBox!.get('last_sync_success') == 'true',
      'last_error': _settingsBox!.get('last_sync_error'),
      'consecutive_failures': int.parse(_settingsBox!.get('consecutive_failures') ?? '0'),
    };
  }
}

/// Background task callback dispatcher
/// This runs in an isolate, so it needs its own initialization
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      // Check connectivity first
      final connectivityManager = ConnectivityManager();
      final isConnected = await connectivityManager.hasInternetConnection();

      if (!isConnected) {
        debugPrint('[BackgroundSync] No internet connection, skipping sync');
        return Future.value(true);
      }

      // Check battery status
      final batteryManager = BatteryOptimizationManager();
      final shouldSync = await batteryManager.shouldPerformSync();

      if (!shouldSync) {
        debugPrint('[BackgroundSync] Battery too low, skipping sync');
        return Future.value(true);
      }

      // Initialize Hive (use init() for background isolates)
      Hive.init(null);

      // Get sync settings from Hive
      final settingsBox = await Hive.openBox<String>('sync_settings');
      final username = settingsBox.get('github_username');
      final repo = settingsBox.get('github_repo');
      final token = settingsBox.get('github_token');

      if (username == null || repo == null || token == null) {
        debugPrint('[BackgroundSync] GitHub credentials not configured');
        await BackgroundSyncService._recordSyncResult(
          success: false,
          error: 'GitHub credentials not configured',
        );
        return Future.value(true);
      }

      // Initialize services
      final keyStorage = KeyStorage();
      await keyStorage.initialize();

      final rootKey = await keyStorage.getRootKey();
      if (rootKey == null) {
        debugPrint('[BackgroundSync] No root key found');
        await BackgroundSyncService._recordSyncResult(
          success: false,
          error: 'No root key found',
        );
        return Future.value(true);
      }

      final cryptoManager = CryptoManager();
      final githubService = GitHubService(
        accessToken: token,
        repoOwner: username,
        repoName: repo,
      );

      final vaultRepository = VaultRepository(
        cryptoManager: cryptoManager,
        keyStorage: keyStorage,
      );
      final notesRepository = NotesRepository(
        cryptoManager: cryptoManager,
        keyStorage: keyStorage,
      );
      final sshRepository = SshRepository(
        cryptoManager: cryptoManager,
        keyStorage: keyStorage,
      );

      final syncEngine = SyncEngine(
        vaultRepository: vaultRepository,
        notesRepository: notesRepository,
        sshRepository: sshRepository,
        githubService: githubService,
        cryptoManager: cryptoManager,
        keyStorage: keyStorage,
      );

      await syncEngine.initialize();

      // Perform sync
      debugPrint('[BackgroundSync] Starting sync...');
      final result = await syncEngine.sync();

      debugPrint('[BackgroundSync] Sync completed: pulled=${result.pulled}, pushed=${result.pushed}');

      await BackgroundSyncService._recordSyncResult(success: true);

      // Clean up
      githubService.dispose();

      return Future.value(true);
    } catch (e, stackTrace) {
      debugPrint('[BackgroundSync] Sync failed: $e');
      debugPrint('[BackgroundSync] Stack trace: $stackTrace');

      await BackgroundSyncService._recordSyncResult(
        success: false,
        error: e.toString(),
      );

      // Return true to avoid excessive retries
      return Future.value(true);
    }
  });
}
