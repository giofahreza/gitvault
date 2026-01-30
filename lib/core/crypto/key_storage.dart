import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Manages secure storage of cryptographic keys in hardware-backed storage
/// Uses platform-specific secure storage (Keychain on iOS, KeyStore on Android)
class KeyStorage {
  final FlutterSecureStorage _secureStorage;

  static const String _rootKeyKey = 'gitvault_root_key';
  static const String _deviceIdKey = 'gitvault_device_id';
  static const String _duressKeyKey = 'gitvault_duress_key';

  KeyStorage({FlutterSecureStorage? secureStorage})
      : _secureStorage = secureStorage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(
                encryptedSharedPreferences: true,
              ),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
            );

  /// Stores the root encryption key securely
  Future<void> storeRootKey(Uint8List key) async {
    final hexKey = _bytesToHex(key);
    await _secureStorage.write(
      key: _rootKeyKey,
      value: hexKey,
    );
  }

  /// Retrieves the root encryption key
  /// Returns null if no key is stored (first launch)
  Future<Uint8List?> getRootKey() async {
    final hexKey = await _secureStorage.read(key: _rootKeyKey);
    if (hexKey == null) return null;

    return _hexToBytes(hexKey);
  }

  /// Checks if a root key exists
  Future<bool> hasRootKey() async {
    final key = await _secureStorage.read(key: _rootKeyKey);
    return key != null;
  }

  /// Deletes the root key (logout/reset)
  Future<void> deleteRootKey() async {
    await _secureStorage.delete(key: _rootKeyKey);
  }

  /// Stores device ID
  Future<void> storeDeviceId(String deviceId) async {
    await _secureStorage.write(key: _deviceIdKey, value: deviceId);
  }

  /// Retrieves device ID
  Future<String?> getDeviceId() async {
    return await _secureStorage.read(key: _deviceIdKey);
  }

  /// Stores duress (panic) key for decoy vault
  Future<void> storeDuressKey(Uint8List key) async {
    final hexKey = _bytesToHex(key);
    await _secureStorage.write(key: _duressKeyKey, value: hexKey);
  }

  /// Retrieves duress key
  Future<Uint8List?> getDuressKey() async {
    final hexKey = await _secureStorage.read(key: _duressKeyKey);
    if (hexKey == null) return null;

    return _hexToBytes(hexKey);
  }

  /// Checks if duress mode is configured
  Future<bool> hasDuressKey() async {
    final key = await _secureStorage.read(key: _duressKeyKey);
    return key != null;
  }

  /// Wipes all stored keys (emergency)
  Future<void> wipeAllKeys() async {
    await _secureStorage.deleteAll();
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
