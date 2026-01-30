import 'dart:typed_data';
import '../crypto/key_storage.dart';
import '../crypto/crypto_manager.dart';

/// Manages duress (panic) mode functionality
/// Allows users to unlock a decoy vault or wipe keys under coercion
class DuressManager {
  final KeyStorage _keyStorage;
  final CryptoManager _cryptoManager;

  DuressManager({
    required KeyStorage keyStorage,
    required CryptoManager cryptoManager,
  })  : _keyStorage = keyStorage,
        _cryptoManager = cryptoManager;

  /// Sets up duress mode with a separate panic key
  Future<void> setupDuressMode() async {
    final duressKey = _cryptoManager.generateRandomKey();
    await _keyStorage.storeDuressKey(duressKey);
  }

  /// Checks if duress mode is configured
  Future<bool> isDuressConfigured() async {
    return await _keyStorage.hasDuressKey();
  }

  /// Retrieves the duress key (for decoy vault)
  Future<Uint8List?> getDuressKey() async {
    return await _keyStorage.getDuressKey();
  }

  /// Wipes all encryption keys (emergency)
  /// WARNING: This is irreversible without recovery kit
  Future<void> executePanicWipe() async {
    await _keyStorage.wipeAllKeys();
  }

  /// Checks if a given key is the duress key
  Future<bool> isDuressKey(Uint8List key) async {
    final duressKey = await _keyStorage.getDuressKey();
    if (duressKey == null) return false;

    // Constant-time comparison to prevent timing attacks
    if (key.length != duressKey.length) return false;

    int result = 0;
    for (int i = 0; i < key.length; i++) {
      result |= key[i] ^ duressKey[i];
    }

    return result == 0;
  }
}
