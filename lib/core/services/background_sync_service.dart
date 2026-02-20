import 'dart:async';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';
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
    bool requireWifi = false,
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

  /// Trigger immediate sync (one-time) via WorkManager.
  /// For a truly immediate sync in the foreground, use [performSyncNow] instead.
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

  /// Perform sync RIGHT NOW in the current (main) isolate.
  /// Unlike [triggerImmediateSync], this does not go through WorkManager —
  /// it runs the sync logic directly and returns the result.
  static Future<SyncResult> performSyncNow() async {
    if (_settingsBox == null) await initialize();

    final keyStorage = KeyStorage();
    await keyStorage.initialize();

    final token = await keyStorage.getGitHubToken();
    final owner = await keyStorage.getRepoOwner();
    final repo = await keyStorage.getRepoName();

    if (token == null || owner == null || repo == null) {
      throw Exception('GitHub credentials not configured. Please set up GitHub sync in settings.');
    }

    final rootKey = await keyStorage.getRootKey();
    if (rootKey == null) {
      throw Exception('No root key found. Please unlock the vault first.');
    }

    final cryptoManager = CryptoManager();
    final githubService = GitHubService(
      accessToken: token,
      repoOwner: owner,
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

    try {
      final result = await syncEngine.sync();
      await _recordSyncResult(success: true);
      return result;
    } catch (e) {
      await _recordSyncResult(success: false, error: e.toString());
      rethrow;
    } finally {
      githubService.dispose();
    }
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

  /// Record sync result (only works in main isolate where _settingsBox is open)
  static Future<void> _recordSyncResult({
    required bool success,
    String? error,
  }) async {
    if (_settingsBox == null) return;

    await _settingsBox!.put('last_sync', DateTime.now().toIso8601String());
    await _settingsBox!.put('last_sync_success', success.toString());
    if (error != null) {
      await _settingsBox!.put('last_sync_error', error);
    } else {
      await _settingsBox!.delete('last_sync_error');
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
/// This runs in an isolated Dart VM — all static state is reset.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      // Enable Flutter plugin registration in this background isolate
      DartPluginRegistrant.ensureInitialized();

      // Initialize Hive with the correct app storage path
      final appDir = await getApplicationDocumentsDirectory();
      Hive.init(appDir.path);

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

      // Read GitHub credentials from KeyStorage box ('secure_keys')
      // NOTE: must match KeyStorage._boxName and its key constants exactly
      final secureBox = await Hive.openBox<String>('secure_keys');
      final token = secureBox.get('gitvault_github_token');
      final owner = secureBox.get('gitvault_repo_owner');
      final repo = secureBox.get('gitvault_repo_name');

      if (token == null || owner == null || repo == null) {
        debugPrint('[BackgroundSync] GitHub credentials not configured');
        await _recordInIsolate(appDir.path, success: false, error: 'GitHub credentials not configured');
        return Future.value(true);
      }

      // Initialize KeyStorage (reuses the already-open 'secure_keys' box)
      final keyStorage = KeyStorage();
      await keyStorage.initialize();

      final rootKey = await keyStorage.getRootKey();
      if (rootKey == null) {
        debugPrint('[BackgroundSync] No root key found');
        await _recordInIsolate(appDir.path, success: false, error: 'No root key found');
        return Future.value(true);
      }

      final cryptoManager = CryptoManager();
      final githubService = GitHubService(
        accessToken: token,
        repoOwner: owner,
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

      await _recordInIsolate(appDir.path, success: true);

      // Clean up
      githubService.dispose();

      return Future.value(true);
    } catch (e, stackTrace) {
      debugPrint('[BackgroundSync] Sync failed: $e');
      debugPrint('[BackgroundSync] Stack trace: $stackTrace');

      try {
        final appDir = await getApplicationDocumentsDirectory();
        await _recordInIsolate(appDir.path, success: false, error: e.toString());
      } catch (_) {}

      // Return true to avoid excessive retries
      return Future.value(true);
    }
  });
}

/// Record sync result inside the background isolate.
/// Cannot use BackgroundSyncService._recordSyncResult because static state is reset.
Future<void> _recordInIsolate(String hivePath, {required bool success, String? error}) async {
  try {
    final box = await Hive.openBox<String>('background_sync_settings');
    await box.put('last_sync', DateTime.now().toIso8601String());
    await box.put('last_sync_success', success.toString());
    if (error != null) {
      await box.put('last_sync_error', error);
    } else {
      await box.delete('last_sync_error');
    }
    final failures = int.parse(box.get('consecutive_failures') ?? '0');
    if (success) {
      await box.put('consecutive_failures', '0');
    } else {
      await box.put('consecutive_failures', (failures + 1).toString());
    }
  } catch (e) {
    debugPrint('[BackgroundSync] Failed to record result: $e');
  }
}
