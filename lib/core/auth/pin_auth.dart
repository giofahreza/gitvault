import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import '../crypto/key_storage.dart';

/// Handles PIN authentication with Argon2id hashing
class PinAuth {
  final KeyStorage _keyStorage;

  PinAuth({required KeyStorage keyStorage}) : _keyStorage = keyStorage;

  /// Hash a PIN using Argon2id with the given salt
  Future<String> _hashPin(String pin, Uint8List salt) async {
    final algorithm = Argon2id(
      memory: 65536, // 64 MB
      parallelism: 2,
      iterations: 3,
      hashLength: 32,
    );

    final secretKey = await algorithm.deriveKey(
      secretKey: SecretKey(utf8.encode(pin)),
      nonce: salt,
    );

    final keyBytes = await secretKey.extractBytes();
    return base64Encode(keyBytes);
  }

  /// Generate a random salt
  Uint8List _generateSalt() {
    final random = Random.secure();
    final salt = Uint8List(16);
    for (int i = 0; i < salt.length; i++) {
      salt[i] = random.nextInt(256);
    }
    return salt;
  }

  /// Set up a new PIN
  Future<void> setupPin(String pin) async {
    await _keyStorage.initialize();
    final salt = _generateSalt();
    final hash = await _hashPin(pin, salt);
    await _keyStorage.storePinHash(hash, base64Encode(salt));
  }

  /// Verify a PIN against stored hash
  Future<bool> verifyPin(String pin) async {
    await _keyStorage.initialize();
    final storedHash = await _keyStorage.getPinHash();
    final storedSalt = await _keyStorage.getPinSalt();

    if (storedHash == null || storedSalt == null) return false;

    final salt = base64Decode(storedSalt);
    final hash = await _hashPin(pin, Uint8List.fromList(salt));
    return hash == storedHash;
  }

  /// Check if PIN is configured
  Future<bool> isPinSetup() async {
    await _keyStorage.initialize();
    return await _keyStorage.hasPinSetup();
  }

  /// Remove PIN
  Future<void> removePin() async {
    await _keyStorage.initialize();
    await _keyStorage.removePin();
  }

  /// Change PIN (verify old, set new)
  Future<bool> changePin(String oldPin, String newPin) async {
    final verified = await verifyPin(oldPin);
    if (!verified) return false;
    await setupPin(newPin);
    return true;
  }
}
