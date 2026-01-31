import 'dart:typed_data';
import 'package:hive/hive.dart';

/// Manages secure storage of cryptographic keys
/// Uses Hive instead of FlutterSecureStorage to avoid KeyStore issues
class KeyStorage {
  late Box<String> _box;
  bool _isInitialized = false;

  static const String _boxName = 'secure_keys';
  static const String _rootKeyKey = 'gitvault_root_key';
  static const String _deviceIdKey = 'gitvault_device_id';
  static const String _duressKeyKey = 'gitvault_duress_key';
  static const String _githubTokenKey = 'gitvault_github_token';
  static const String _repoOwnerKey = 'gitvault_repo_owner';
  static const String _repoNameKey = 'gitvault_repo_name';
  static const String _biometricEnabledKey = 'gitvault_biometric_enabled';
  static const String _clipboardClearSecondsKey = 'gitvault_clipboard_clear_seconds';
  static const String _themeModeKey = 'gitvault_theme_mode';
  static const String _pinHashKey = 'gitvault_pin_hash';
  static const String _pinSaltKey = 'gitvault_pin_salt';
  static const String _autoSyncIntervalKey = 'gitvault_auto_sync_interval';

  /// Initialize the storage box
  Future<void> initialize() async {
    if (_isInitialized) return;
    _box = await Hive.openBox<String>(_boxName);
    _isInitialized = true;
  }

  void _ensureInitialized() {
    if (!_isInitialized) {
      throw StateError('KeyStorage not initialized. Call initialize() first.');
    }
  }

  /// Stores the root encryption key securely
  Future<void> storeRootKey(Uint8List key) async {
    _ensureInitialized();
    final hexKey = _bytesToHex(key);
    await _box.put(_rootKeyKey, hexKey);
  }

  /// Retrieves the root encryption key
  /// Returns null if no key is stored (first launch)
  Future<Uint8List?> getRootKey() async {
    _ensureInitialized();
    final hexKey = _box.get(_rootKeyKey);
    if (hexKey == null) return null;

    return _hexToBytes(hexKey);
  }

  /// Checks if a root key exists
  Future<bool> hasRootKey() async {
    _ensureInitialized();
    final key = _box.get(_rootKeyKey);
    return key != null;
  }

  /// Deletes the root key (logout/reset)
  Future<void> deleteRootKey() async {
    _ensureInitialized();
    await _box.delete(_rootKeyKey);
  }

  /// Stores device ID
  Future<void> storeDeviceId(String deviceId) async {
    _ensureInitialized();
    await _box.put(_deviceIdKey, deviceId);
  }

  /// Retrieves device ID
  Future<String?> getDeviceId() async {
    _ensureInitialized();
    return _box.get(_deviceIdKey);
  }

  /// Stores duress (panic) key for decoy vault
  Future<void> storeDuressKey(Uint8List key) async {
    _ensureInitialized();
    final hexKey = _bytesToHex(key);
    await _box.put(_duressKeyKey, hexKey);
  }

  /// Retrieves duress key
  Future<Uint8List?> getDuressKey() async {
    _ensureInitialized();
    final hexKey = _box.get(_duressKeyKey);
    if (hexKey == null) return null;

    return _hexToBytes(hexKey);
  }

  /// Checks if duress mode is configured
  Future<bool> hasDuressKey() async {
    _ensureInitialized();
    final key = _box.get(_duressKeyKey);
    return key != null;
  }

  /// Stores GitHub credentials
  Future<void> storeGitHubCredentials({
    required String token,
    required String repoOwner,
    required String repoName,
  }) async {
    _ensureInitialized();
    await _box.put(_githubTokenKey, token);
    await _box.put(_repoOwnerKey, repoOwner);
    await _box.put(_repoNameKey, repoName);
  }

  /// Retrieves GitHub token
  Future<String?> getGitHubToken() async {
    _ensureInitialized();
    return _box.get(_githubTokenKey);
  }

  /// Retrieves GitHub repo owner
  Future<String?> getRepoOwner() async {
    _ensureInitialized();
    return _box.get(_repoOwnerKey);
  }

  /// Retrieves GitHub repo name
  Future<String?> getRepoName() async {
    _ensureInitialized();
    return _box.get(_repoNameKey);
  }

  /// Checks if GitHub is configured
  Future<bool> hasGitHubCredentials() async {
    _ensureInitialized();
    final token = _box.get(_githubTokenKey);
    return token != null && token.isNotEmpty;
  }

  /// Stores biometric enabled preference
  Future<void> setBiometricEnabled(bool enabled) async {
    _ensureInitialized();
    await _box.put(_biometricEnabledKey, enabled.toString());
  }

  /// Retrieves biometric enabled preference (defaults to false)
  Future<bool> getBiometricEnabled() async {
    _ensureInitialized();
    final value = _box.get(_biometricEnabledKey);
    if (value == null) return false; // Default to disabled
    return value == 'true';
  }

  /// Stores clipboard auto-clear seconds preference
  Future<void> setClipboardClearSeconds(int seconds) async {
    _ensureInitialized();
    await _box.put(_clipboardClearSecondsKey, seconds.toString());
  }

  /// Retrieves clipboard auto-clear seconds (defaults to 30)
  Future<int> getClipboardClearSeconds() async {
    _ensureInitialized();
    final value = _box.get(_clipboardClearSecondsKey);
    if (value == null) return 30;
    return int.tryParse(value) ?? 30;
  }

  /// Stores theme mode preference
  Future<void> setThemeMode(String mode) async {
    _ensureInitialized();
    await _box.put(_themeModeKey, mode);
  }

  /// Retrieves theme mode preference (defaults to 'system')
  Future<String> getThemeMode() async {
    _ensureInitialized();
    final value = _box.get(_themeModeKey);
    return value ?? 'system';
  }

  /// Stores PIN hash and salt
  Future<void> storePinHash(String hash, String salt) async {
    _ensureInitialized();
    await _box.put(_pinHashKey, hash);
    await _box.put(_pinSaltKey, salt);
  }

  /// Retrieves PIN hash
  Future<String?> getPinHash() async {
    _ensureInitialized();
    return _box.get(_pinHashKey);
  }

  /// Retrieves PIN salt
  Future<String?> getPinSalt() async {
    _ensureInitialized();
    return _box.get(_pinSaltKey);
  }

  /// Checks if PIN is configured
  Future<bool> hasPinSetup() async {
    _ensureInitialized();
    return _box.get(_pinHashKey) != null;
  }

  /// Removes PIN
  Future<void> removePin() async {
    _ensureInitialized();
    await _box.delete(_pinHashKey);
    await _box.delete(_pinSaltKey);
  }

  /// Stores auto-sync interval in minutes (0 = off)
  Future<void> setAutoSyncInterval(int minutes) async {
    _ensureInitialized();
    await _box.put(_autoSyncIntervalKey, minutes.toString());
  }

  /// Retrieves auto-sync interval in minutes (defaults to 5)
  Future<int> getAutoSyncInterval() async {
    _ensureInitialized();
    final value = _box.get(_autoSyncIntervalKey);
    if (value == null) return 5;
    return int.tryParse(value) ?? 5;
  }

  /// Wipes all stored keys (emergency)
  Future<void> wipeAllKeys() async {
    _ensureInitialized();
    await _box.clear();
  }

  /// Converts bytes to hex string
  String _bytesToHex(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Converts hex string to bytes
  Uint8List _hexToBytes(String hex) {
    final result = Uint8List(hex.length ~/ 2);
    for (int i = 0; i < result.length; i++) {
      result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return result;
  }
}
