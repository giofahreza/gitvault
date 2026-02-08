import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:hive/hive.dart';
import '../../data/models/ssh_credential.dart';
import 'ssh_connection_manager.dart';

/// Persistent SSH session service - Just like Termux!
/// Keeps SSH sessions alive in background with notifications and wake locks
class PersistentSshService {
  static final PersistentSshService _instance = PersistentSshService._internal();
  factory PersistentSshService() => _instance;
  PersistentSshService._internal();

  final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();
  final Map<String, SshSessionWrapper> _activeSessions = {};
  bool _initialized = false;
  int _notificationIdCounter = 100;

  /// Initialize the persistent SSH service
  Future<void> initialize() async {
    if (_initialized) return;

    // Initialize notifications
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidInit);

    await _notifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );

    // Create notification channel
    const channel = AndroidNotificationChannel(
      'ssh_sessions',
      'SSH Sessions',
      description: 'Persistent SSH terminal sessions',
      importance: Importance.low,
      playSound: false,
      enableVibration: false,
    );

    await _notifications
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    // Restore saved sessions
    await _restoreSessions();

    _initialized = true;
  }

  /// Create a new SSH session and keep it alive in background
  Future<SshSessionWrapper> createSession({
    required SshCredential credential,
    bool persistent = true,
  }) async {
    if (!_initialized) await initialize();

    final sessionId = '${credential.uuid}_${DateTime.now().millisecondsSinceEpoch}';
    final notificationId = _notificationIdCounter++;

    final wrapper = SshSessionWrapper(
      sessionId: sessionId,
      credential: credential,
      notificationId: notificationId,
      persistent: persistent,
    );

    _activeSessions[sessionId] = wrapper;

    // Connect
    await wrapper.connect();

    // Show notification if persistent
    if (persistent) {
      await _showSessionNotification(wrapper);
      await WakelockPlus.enable();
    }

    // Save session
    await _saveSession(wrapper);

    debugPrint('[PersistentSSH] Created session $sessionId');
    return wrapper;
  }

  /// Get an existing session
  SshSessionWrapper? getSession(String sessionId) {
    return _activeSessions[sessionId];
  }

  /// Get all active sessions
  List<SshSessionWrapper> getAllSessions() {
    return _activeSessions.values.toList();
  }

  /// Close a session
  Future<void> closeSession(String sessionId) async {
    final session = _activeSessions[sessionId];
    if (session == null) return;

    await session.disconnect();
    _activeSessions.remove(sessionId);

    // Cancel notification
    if (session.persistent) {
      await _notifications.cancel(session.notificationId);
    }

    // Remove from storage
    await _removeSavedSession(sessionId);

    // Disable wake lock if no more sessions
    if (_activeSessions.isEmpty) {
      await WakelockPlus.disable();
    }

    debugPrint('[PersistentSSH] Closed session $sessionId');
  }

  /// Close all sessions
  Future<void> closeAllSessions() async {
    for (final sessionId in _activeSessions.keys.toList()) {
      await closeSession(sessionId);
    }
  }

  /// Show notification for active session
  Future<void> _showSessionNotification(SshSessionWrapper session) async {
    final notification = AndroidNotificationDetails(
      'ssh_sessions',
      'SSH Sessions',
      channelDescription: 'Persistent SSH terminal sessions',
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      autoCancel: false,
      showWhen: true,
      when: session.startTime.millisecondsSinceEpoch,
      usesChronometer: true,
      icon: '@mipmap/ic_launcher',
      actions: [
        const AndroidNotificationAction(
          'disconnect',
          'Disconnect',
          showsUserInterface: false,
        ),
      ],
    );

    await _notifications.show(
      session.notificationId,
      '${session.credential.label}',
      '${session.credential.username}@${session.credential.host}:${session.credential.port}',
      NotificationDetails(android: notification),
      payload: session.sessionId,
    );
  }

  /// Update notification (e.g., when data is transferred)
  Future<void> updateSessionNotification(SshSessionWrapper session, {String? subtitle}) async {
    final notification = AndroidNotificationDetails(
      'ssh_sessions',
      'SSH Sessions',
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      autoCancel: false,
      showWhen: true,
      when: session.startTime.millisecondsSinceEpoch,
      usesChronometer: true,
      icon: '@mipmap/ic_launcher',
      actions: [
        const AndroidNotificationAction(
          'disconnect',
          'Disconnect',
          showsUserInterface: false,
        ),
      ],
    );

    await _notifications.show(
      session.notificationId,
      session.credential.label,
      subtitle ?? '${session.credential.username}@${session.credential.host}',
      NotificationDetails(android: notification),
      payload: session.sessionId,
    );
  }

  /// Handle notification tap
  void _onNotificationTapped(NotificationResponse response) {
    if (response.actionId == 'disconnect') {
      final sessionId = response.payload;
      if (sessionId != null) {
        closeSession(sessionId);
      }
    }
  }

  /// Save session to Hive for restoration
  Future<void> _saveSession(SshSessionWrapper session) async {
    if (!session.persistent) return;

    final box = await Hive.openBox<String>('ssh_sessions');
    final data = {
      'sessionId': session.sessionId,
      'credentialUuid': session.credential.uuid,
      'startTime': session.startTime.toIso8601String(),
      'notificationId': session.notificationId,
    };
    await box.put(session.sessionId, jsonEncode(data));
  }

  /// Remove saved session
  Future<void> _removeSavedSession(String sessionId) async {
    final box = await Hive.openBox<String>('ssh_sessions');
    await box.delete(sessionId);
  }

  /// Restore sessions on app restart
  Future<void> _restoreSessions() async {
    try {
      final box = await Hive.openBox<String>('ssh_sessions');

      for (final key in box.keys) {
        final dataStr = box.get(key);
        if (dataStr == null) continue;

        final data = jsonDecode(dataStr) as Map<String, dynamic>;
        final sessionId = data['sessionId'] as String;

        // For now, don't auto-restore (user can manually reconnect)
        // In Termux style, we'd restore but that requires more complex state management
        debugPrint('[PersistentSSH] Found saved session: $sessionId');
      }
    } catch (e) {
      debugPrint('[PersistentSSH] Failed to restore sessions: $e');
    }
  }

  /// Clear all saved sessions
  Future<void> clearSavedSessions() async {
    final box = await Hive.openBox<String>('ssh_sessions');
    await box.clear();
  }

  /// Get session count
  int get activeSessionCount => _activeSessions.length;

  /// Check if any sessions are active
  bool get hasActiveSessions => _activeSessions.isNotEmpty;
}

/// Wrapper for SSH session with metadata and state
class SshSessionWrapper {
  final String sessionId;
  final SshCredential credential;
  final int notificationId;
  final bool persistent;
  final DateTime startTime;

  late final SshConnectionManager _connectionManager;
  bool _isConnected = false;

  final _stateController = StreamController<SshSessionState>.broadcast();
  Stream<SshSessionState> get stateStream => _stateController.stream;

  SshSessionWrapper({
    required this.sessionId,
    required this.credential,
    required this.notificationId,
    this.persistent = true,
  }) : startTime = DateTime.now() {
    _connectionManager = SshConnectionManager(credential: credential);
  }

  bool get isConnected => _isConnected;
  SshConnectionManager get connectionManager => _connectionManager;

  /// Connect to SSH server
  Future<void> connect() async {
    try {
      _stateController.add(SshSessionState.connecting);
      await _connectionManager.connect();
      _isConnected = true;
      _stateController.add(SshSessionState.connected);

      // Listen for disconnection
      _connectionManager.session?.done.then((_) {
        _isConnected = false;
        _stateController.add(SshSessionState.disconnected);
      });
    } catch (e) {
      _isConnected = false;
      _stateController.add(SshSessionState.error);
      rethrow;
    }
  }

  /// Disconnect from SSH server
  Future<void> disconnect() async {
    await _connectionManager.disconnect();
    _isConnected = false;
    _stateController.add(SshSessionState.disconnected);
  }

  /// Reconnect if disconnected
  Future<void> reconnect() async {
    if (!_isConnected) {
      await connect();
    }
  }

  /// Get duration since session started
  Duration get duration => DateTime.now().difference(startTime);

  /// Clean up resources
  void dispose() {
    _stateController.close();
  }
}

/// SSH session states
enum SshSessionState {
  connecting,
  connected,
  disconnected,
  error,
}
