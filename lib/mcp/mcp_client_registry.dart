import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';

import 'mcp_models.dart';

class McpClientRegistry extends ChangeNotifier {
  static const String settingsBoxName = 'mcp_settings';
  static const String activityBoxName = 'mcp_activity';
  static const String _enabledKey = 'enabled';
  static const String _portKey = 'port';
  static const String _launchAtStartupKey = 'launch_at_startup';
  static const String _keepInTrayKey = 'keep_in_tray';
  static const String _clientPrefix = 'client:';
  static const int defaultPort = 39471;
  static const int activityRetentionDays = 30;
  static const int maximumActivityRecords = 1000;

  final Uuid _uuid = const Uuid();
  final Random _random = Random.secure();
  final Map<String, McpClientRegistration> _clients = {};
  final List<McpActivityRecord> _activity = [];

  late Box<String> _settingsBox;
  late Box<String> _activityBox;
  Future<void>? _initializeFuture;
  Future<void> _writeQueue = Future<void>.value();
  bool _initialized = false;
  bool _enabled = false;
  bool _launchAtStartup = false;
  bool _keepInTray = true;
  int _port = defaultPort;

  bool get isInitialized => _initialized;
  bool get enabled => _enabled;
  bool get launchAtStartup => _launchAtStartup;
  bool get keepInTray => _keepInTray;
  int get port => _port;

  List<McpClientRegistration> get clients {
    final result = _clients.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return List.unmodifiable(result);
  }

  List<McpClientRegistration> get activeClients =>
      List.unmodifiable(clients.where((client) => client.isActive));

  List<McpActivityRecord> get activity => List.unmodifiable(_activity);

  Future<void> initialize() async {
    if (_initialized) return;
    _initializeFuture ??= _initialize();
    try {
      await _initializeFuture;
    } catch (_) {
      _initializeFuture = null;
      rethrow;
    }
  }

  Future<void> _initialize() async {
    _settingsBox = await Hive.openBox<String>(settingsBoxName);
    _activityBox = await Hive.openBox<String>(activityBoxName);

    _enabled = _settingsBox.get(_enabledKey) == 'true';
    _launchAtStartup = _settingsBox.get(_launchAtStartupKey) == 'true';
    _keepInTray = _settingsBox.get(_keepInTrayKey) != 'false';
    _port = int.tryParse(_settingsBox.get(_portKey) ?? '') ?? defaultPort;
    if (_port < 1024 || _port > 65535) _port = defaultPort;

    for (final key in _settingsBox.keys.whereType<String>()) {
      if (!key.startsWith(_clientPrefix)) continue;
      final encoded = _settingsBox.get(key);
      if (encoded == null) continue;
      try {
        final client = McpClientRegistration.fromJson(
          jsonDecode(encoded) as Map<String, dynamic>,
        );
        if (client.id.isNotEmpty && client.tokenVerifier.isNotEmpty) {
          _clients[client.id] = client;
        }
      } catch (_) {
        // Ignore malformed local registration records.
      }
    }

    for (final encoded in _activityBox.values) {
      try {
        _activity.add(
          McpActivityRecord.fromJson(
            jsonDecode(encoded) as Map<String, dynamic>,
          ),
        );
      } catch (_) {
        // Ignore malformed local audit records.
      }
    }
    _activity.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    _initialized = true;
    await _pruneActivity();
  }

  Future<void> setEnabled(bool value) async {
    await initialize();
    if (_enabled == value) return;
    _enabled = value;
    await _settingsBox.put(_enabledKey, value.toString());
    notifyListeners();
  }

  Future<void> setPort(int value) async {
    await initialize();
    if (value < 1024 || value > 65535) {
      throw const McpOperationException(
        'invalid_input',
        'Port must be between 1024 and 65535.',
      );
    }
    if (_port == value) return;
    _port = value;
    await _settingsBox.put(_portKey, value.toString());
    notifyListeners();
  }

  Future<void> setLaunchAtStartup(bool value) async {
    await initialize();
    if (_launchAtStartup == value) return;
    _launchAtStartup = value;
    await _settingsBox.put(_launchAtStartupKey, value.toString());
    notifyListeners();
  }

  Future<void> setKeepInTray(bool value) async {
    await initialize();
    if (_keepInTray == value) return;
    _keepInTray = value;
    await _settingsBox.put(_keepInTrayKey, value.toString());
    notifyListeners();
  }

  Future<McpIssuedCredential> createClient({
    required String displayName,
    required McpClientTransport transport,
    required Set<McpPermission> permissions,
    Set<String> allowedTags = const {},
    Set<String> deniedTags = const {},
    McpWritePolicy writePolicy = McpWritePolicy.askEveryTime,
    Set<McpPermission> approvalExemptPermissions = const {},
  }) async {
    await initialize();
    final normalizedName = displayName.trim();
    if (normalizedName.isEmpty || normalizedName.length > 80) {
      throw const McpOperationException(
        'invalid_input',
        'AI app name must contain 1 to 80 characters.',
      );
    }

    final id = _uuid.v4();
    final token = _createToken(id);
    final client = McpClientRegistration(
      id: id,
      displayName: normalizedName,
      transport: transport,
      permissions: Set.unmodifiable(permissions),
      allowedTags: _normalizeTags(allowedTags),
      deniedTags: _normalizeTags(deniedTags),
      writePolicy: writePolicy,
      approvalExemptPermissions: Set.unmodifiable(
        approvalExemptPermissions.where(
          (value) => value.isWrite && permissions.contains(value),
        ),
      ),
      tokenVerifier: _tokenVerifier(token),
      createdAt: DateTime.now().toUtc(),
    );
    _clients[id] = client;
    await _persistClient(client);
    notifyListeners();
    return McpIssuedCredential(client: client, token: token);
  }

  McpClientRegistration? getClient(String id) => _clients[id];

  Future<McpClientRegistration?> authenticateBearer(String bearerToken) async {
    await initialize();
    if (!_enabled) return null;
    final parts = bearerToken.split('.');
    if (parts.length != 3 || parts.first != 'gvmcp') return null;
    final client = _clients[parts[1]];
    if (client == null || !client.isActive) return null;

    final actual = _tokenVerifier(bearerToken);
    if (!_constantTimeEquals(actual, client.tokenVerifier)) return null;
    await touchClient(client.id);
    return _clients[client.id];
  }

  Future<McpIssuedCredential> rotateCredential(String clientId) async {
    await initialize();
    final client = _requireClient(clientId);
    final token = _createToken(client.id);
    final updated = client.copyWith(
      tokenVerifier: _tokenVerifier(token),
      clearRevokedAt: true,
    );
    _clients[client.id] = updated;
    await _persistClient(updated);
    notifyListeners();
    return McpIssuedCredential(client: updated, token: token);
  }

  Future<void> updateClient(
    String clientId, {
    String? displayName,
    Set<McpPermission>? permissions,
    Set<String>? allowedTags,
    Set<String>? deniedTags,
    McpWritePolicy? writePolicy,
    Set<McpPermission>? approvalExemptPermissions,
  }) async {
    await initialize();
    final client = _requireClient(clientId);
    final normalizedName = displayName?.trim();
    if (normalizedName != null &&
        (normalizedName.isEmpty || normalizedName.length > 80)) {
      throw const McpOperationException(
        'invalid_input',
        'AI app name must contain 1 to 80 characters.',
      );
    }

    final nextPermissions = permissions ?? client.permissions;
    final requestedExemptions =
        approvalExemptPermissions ?? client.approvalExemptPermissions;
    final updated = client.copyWith(
      displayName: normalizedName,
      permissions: permissions == null ? null : Set.unmodifiable(permissions),
      allowedTags: allowedTags == null ? null : _normalizeTags(allowedTags),
      deniedTags: deniedTags == null ? null : _normalizeTags(deniedTags),
      writePolicy: writePolicy,
      approvalExemptPermissions: Set.unmodifiable(
        requestedExemptions.where(
          (value) => value.isWrite && nextPermissions.contains(value),
        ),
      ),
    );
    _clients[client.id] = updated;
    await _persistClient(updated);
    notifyListeners();
  }

  Future<void> allowWriteWithoutApproval(
    String clientId,
    McpPermission permission,
  ) async {
    await initialize();
    final client = _requireClient(clientId);
    if (!permission.isWrite) return;
    await updateClient(
      clientId,
      permissions: {...client.permissions, permission},
      approvalExemptPermissions: {
        ...client.approvalExemptPermissions,
        permission,
      },
    );
  }

  Future<void> touchClient(String clientId) async {
    final client = _clients[clientId];
    if (client == null || !client.isActive) return;
    final now = DateTime.now().toUtc();
    if (client.lastUsedAt != null &&
        now.difference(client.lastUsedAt!) < const Duration(minutes: 1)) {
      return;
    }
    final updated = client.copyWith(lastUsedAt: now);
    _clients[clientId] = updated;
    await _persistClient(updated);
    notifyListeners();
  }

  Future<void> revokeClient(String clientId) async {
    await initialize();
    final client = _requireClient(clientId);
    if (!client.isActive) return;
    final updated = client.copyWith(revokedAt: DateTime.now().toUtc());
    _clients[clientId] = updated;
    await _persistClient(updated);
    notifyListeners();
  }

  Future<void> restoreClient(String clientId) async {
    await initialize();
    final client = _requireClient(clientId);
    final updated = client.copyWith(clearRevokedAt: true);
    _clients[clientId] = updated;
    await _persistClient(updated);
    notifyListeners();
  }

  Future<void> removeClient(String clientId) async {
    await initialize();
    _clients.remove(clientId);
    await _settingsBox.delete('$_clientPrefix$clientId');
    notifyListeners();
  }

  Future<void> revokeAllClients() async {
    await initialize();
    final now = DateTime.now().toUtc();
    for (final client in _clients.values.toList()) {
      if (!client.isActive) continue;
      final updated = client.copyWith(revokedAt: now);
      _clients[client.id] = updated;
      await _persistClient(updated);
    }
    notifyListeners();
  }

  Future<void> recordActivity(McpActivityRecord record) async {
    await initialize();
    _activity.insert(0, record);
    await _enqueueWrite(
      () => _activityBox.put(record.id, jsonEncode(record.toJson())),
    );
    await _pruneActivity();
    notifyListeners();
  }

  Future<void> clearActivity() async {
    await initialize();
    _activity.clear();
    await _activityBox.clear();
    notifyListeners();
  }

  Future<void> _pruneActivity() async {
    final cutoff = DateTime.now()
        .toUtc()
        .subtract(const Duration(days: activityRetentionDays));
    final remove = _activity
        .where((record) => record.timestamp.isBefore(cutoff))
        .map((record) => record.id)
        .toSet();
    if (_activity.length - remove.length > maximumActivityRecords) {
      remove.addAll(
        _activity
            .where((record) => !remove.contains(record.id))
            .skip(maximumActivityRecords)
            .map((record) => record.id),
      );
    }
    if (remove.isEmpty) return;
    _activity.removeWhere((record) => remove.contains(record.id));
    await _activityBox.deleteAll(remove);
  }

  McpClientRegistration _requireClient(String clientId) {
    final client = _clients[clientId];
    if (client == null) {
      throw const McpOperationException(
        'client_not_paired',
        'The AI app is not connected to GitVault.',
      );
    }
    return client;
  }

  Future<void> _persistClient(McpClientRegistration client) {
    return _enqueueWrite(
      () => _settingsBox.put(
        '$_clientPrefix${client.id}',
        jsonEncode(client.toJson()),
      ),
    );
  }

  Future<T> _enqueueWrite<T>(Future<T> Function() operation) {
    final scheduled = _writeQueue.then((_) => operation());
    _writeQueue = scheduled.then<void>((_) {}, onError: (_, __) {});
    return scheduled;
  }

  String _createToken(String clientId) {
    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    final secret = base64UrlEncode(bytes).replaceAll('=', '');
    return 'gvmcp.$clientId.$secret';
  }

  String _tokenVerifier(String token) =>
      sha256.convert(utf8.encode(token)).toString();

  bool _constantTimeEquals(String left, String right) {
    if (left.length != right.length) return false;
    var difference = 0;
    for (var index = 0; index < left.length; index++) {
      difference |= left.codeUnitAt(index) ^ right.codeUnitAt(index);
    }
    return difference == 0;
  }

  Set<String> _normalizeTags(Iterable<String> tags) {
    final normalized = tags
        .map(
          (tag) => tag.trim().replaceFirst(RegExp(r'^#'), '').toLowerCase(),
        )
        .where((tag) => tag.isNotEmpty)
        .toSet();
    if (normalized.length > 50 || normalized.any((tag) => tag.length > 80)) {
      throw const McpOperationException(
        'invalid_input',
        'Tag scopes can contain up to 50 tags of at most 80 characters.',
      );
    }
    return Set.unmodifiable(normalized);
  }
}
