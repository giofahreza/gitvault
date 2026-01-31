import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
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

  /// Sets up duress mode with a PIN-derived key
  Future<void> setupDuressMode({String? pin}) async {
    Uint8List duressKey;
    if (pin != null && pin.isNotEmpty) {
      // Derive key from user's PIN so it's reproducible
      duressKey = await _deriveKeyFromPin(pin);
    } else {
      duressKey = _cryptoManager.generateRandomKey();
    }
    await _keyStorage.storeDuressKey(duressKey);
  }

  /// Derives a 32-byte key from a PIN
  Future<Uint8List> _deriveKeyFromPin(String pin) async {
    final argon2id = Argon2id(
      memory: 10000,
      iterations: 2,
      parallelism: 1,
      hashLength: 32,
    );
    final hash = await argon2id.deriveKey(
      secretKey: SecretKey(utf8.encode(pin)),
      nonce: utf8.encode('gitvault-duress-pin'),
    );
    final bytes = await hash.extractBytes();
    return Uint8List.fromList(bytes);
  }

  /// Checks if a PIN matches the stored duress key
  Future<bool> verifyDuressPin(String pin) async {
    final derivedKey = await _deriveKeyFromPin(pin);
    return await isDuressKey(derivedKey);
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
