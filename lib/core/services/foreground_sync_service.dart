import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../../data/repositories/sync_engine.dart';
import 'background_sync_service.dart';

/// Coordinates quiet foreground sync while the unlocked app is open.
///
/// WorkManager covers Android background sync, but web and foreground edits
/// need a lightweight coordinator that can debounce local writes and poll for
/// remote changes without blocking user interactions.
class ForegroundSyncService {
  static const String _secureKeysBoxName = 'secure_keys';
  static const String _rootKeyKey = 'gitvault_root_key';
  static const String _githubTokenKey = 'gitvault_github_token';
  static const String _repoOwnerKey = 'gitvault_repo_owner';
  static const String _repoNameKey = 'gitvault_repo_name';
  static const String _autoSyncIntervalKey = 'gitvault_auto_sync_interval';

  static final ValueNotifier<int> syncRevision = ValueNotifier<int>(0);

  static Timer? _debounceTimer;
  static Timer? _periodicTimer;
  static Future<SyncResult?>? _activeSync;
  static bool _queuedAfterActiveSync = false;
  static bool _periodicStarted = false;
  static int _scheduleSerial = 0;

  static SyncResult? lastResult;
  static Object? lastError;

  static Future<void> startPeriodicSync() async {
    _periodicStarted = true;
    await refreshPeriodicSync();

    // Pull remote updates shortly after unlock/open. The actual sync method
    // exits quietly when GitHub is not configured.
    scheduleSync(
      reason: 'app unlocked',
      debounce: const Duration(seconds: 2),
    );
  }

  static Future<void> refreshPeriodicSync() async {
    _periodicTimer?.cancel();
    _periodicTimer = null;

    if (!_periodicStarted) return;

    if (!_isSecureKeysBoxOpen()) return;
    final box = Hive.box<String>(_secureKeysBoxName);
    if (!_hasSyncCredentials(box)) return;

    final intervalMinutes =
        int.tryParse(box.get(_autoSyncIntervalKey) ?? '') ?? 5;
    if (intervalMinutes <= 0) return;

    _periodicTimer = Timer.periodic(
      Duration(minutes: intervalMinutes),
      (_) => unawaited(syncNow(reason: 'foreground periodic sync')),
    );
  }

  static void stopPeriodicSync() {
    _periodicStarted = false;
    _periodicTimer?.cancel();
    _periodicTimer = null;
  }

  static void scheduleSync({
    required String reason,
    Duration debounce = const Duration(seconds: 4),
  }) {
    final serial = ++_scheduleSerial;
    unawaited(_scheduleSyncIfConfigured(
      serial: serial,
      reason: reason,
      debounce: debounce,
    ));
  }

  static Future<void> _scheduleSyncIfConfigured({
    required int serial,
    required String reason,
    required Duration debounce,
  }) async {
    if (!await _isSyncConfigured()) return;
    if (serial != _scheduleSerial) return;

    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, () {
      _debounceTimer = null;
      unawaited(syncNow(reason: reason));
    });
  }

  static Future<SyncResult?> syncNow({required String reason}) async {
    final activeSync = _activeSync;
    if (activeSync != null) {
      _queuedAfterActiveSync = true;
      return activeSync;
    }

    _debounceTimer?.cancel();
    _debounceTimer = null;

    late final Future<SyncResult?> operation;
    operation = _performSync(reason).whenComplete(() {
      if (identical(_activeSync, operation)) {
        _activeSync = null;
      }

      if (_queuedAfterActiveSync) {
        _queuedAfterActiveSync = false;
        scheduleSync(
          reason: 'queued foreground sync',
          debounce: const Duration(seconds: 2),
        );
      }
    });

    _activeSync = operation;
    return operation;
  }

  static Future<SyncResult?> _performSync(String reason) async {
    try {
      if (!await _isSyncConfigured()) {
        lastError = null;
        return null;
      }

      final result = await BackgroundSyncService.performSyncNow();
      lastResult = result;
      lastError = null;
      syncRevision.value++;
      return result;
    } catch (error, stackTrace) {
      lastError = error;
      debugPrint('[ForegroundSync] $reason failed: $error');
      debugPrint('$stackTrace');
      return null;
    }
  }

  static Future<bool> _isSyncConfigured() async {
    try {
      if (!_isSecureKeysBoxOpen()) return false;
      return _hasSyncCredentials(Hive.box<String>(_secureKeysBoxName));
    } catch (_) {
      return false;
    }
  }

  static bool _isSecureKeysBoxOpen() {
    try {
      return Hive.isBoxOpen(_secureKeysBoxName);
    } catch (_) {
      return false;
    }
  }

  static bool _hasSyncCredentials(Box<String> box) {
    return box.get(_rootKeyKey) != null &&
        box.get(_githubTokenKey) != null &&
        box.get(_repoOwnerKey) != null &&
        box.get(_repoNameKey) != null;
  }
}
