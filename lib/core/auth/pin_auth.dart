import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import '../crypto/key_storage.dart';

/// Handles PIN authentication with platform-specific password hashing.
class PinAuth {
  final KeyStorage _keyStorage;
  final _PinHashProfile _nativeProfile;
  final _PinHashProfile _webProfile;
  final _PinHashProfile _preferredProfile;

  PinAuth({required KeyStorage keyStorage})
      : this._(
          keyStorage: keyStorage,
          nativeProfile: _PinHashProfile.nativeArgon2id(),
          webProfile: _PinHashProfile.webPbkdf2(),
          useWebHashing: kIsWeb,
        );

  @visibleForTesting
  PinAuth.forTesting({
    required KeyStorage keyStorage,
    bool useWebHashing = false,
    int argonMemory = _PinHashProfile.nativeArgonMemory,
    int argonIterations = _PinHashProfile.nativeArgonIterations,
    int argonParallelism = _PinHashProfile.nativeArgonParallelism,
    int pbkdf2Iterations = _PinHashProfile.webPbkdf2Iterations,
  }) : this._(
          keyStorage: keyStorage,
          nativeProfile: _PinHashProfile.nativeArgon2id(
            memory: argonMemory,
            iterations: argonIterations,
            parallelism: argonParallelism,
          ),
          webProfile: _PinHashProfile.webPbkdf2(
            iterations: pbkdf2Iterations,
          ),
          useWebHashing: useWebHashing,
        );

  PinAuth._({
    required KeyStorage keyStorage,
    required _PinHashProfile nativeProfile,
    required _PinHashProfile webProfile,
    required bool useWebHashing,
  })  : _keyStorage = keyStorage,
        _nativeProfile = nativeProfile,
        _webProfile = webProfile,
        _preferredProfile = useWebHashing ? webProfile : nativeProfile;

  static final RegExp _pinPattern = RegExp(r'^\d{4,6}$');
  static const String _storedHashVersion = 'v2';

  /// Hash a PIN using the selected platform profile.
  Future<_PinHash> _hashPin(
    String pin,
    Uint8List salt,
    _PinHashProfile profile,
  ) async {
    final pinBytes = utf8.encode(pin);
    late final SecretKey secretKey;

    switch (profile.algorithm) {
      case _PinHashAlgorithm.argon2id:
        final algorithm = Argon2id(
          memory: profile.memory,
          parallelism: profile.parallelism,
          iterations: profile.iterations,
          hashLength: profile.hashLength,
        );
        secretKey = await algorithm.deriveKey(
          secretKey: SecretKey(pinBytes),
          nonce: salt,
        );
        break;
      case _PinHashAlgorithm.pbkdf2Sha256:
        // On Flutter web this is backed by WebCrypto when available. The
        // previous Argon2id profile is pure Dart in browsers and can block PIN
        // entry for several seconds on slower devices.
        final algorithm = Pbkdf2.hmacSha256(
          iterations: profile.iterations,
          bits: profile.bits,
        );
        secretKey = await algorithm.deriveKey(
          secretKey: SecretKey(pinBytes),
          nonce: salt,
        );
        break;
    }

    final hash = base64Encode(await secretKey.extractBytes());
    return _PinHash(profile: profile, hash: hash);
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
    if (!_pinPattern.hasMatch(pin)) {
      throw ArgumentError('PIN must be 4-6 digits');
    }

    await _keyStorage.initialize();
    final salt = _generateSalt();
    final hash = await _hashPin(pin, salt, _preferredProfile);
    await _keyStorage.storePinHash(
      hash.toStorageValue(),
      base64Encode(salt),
      length: pin.length,
    );
  }

  /// Verify a PIN against stored hash
  Future<bool> verifyPin(String pin) async {
    if (!_pinPattern.hasMatch(pin)) return false;

    await _keyStorage.initialize();
    final storedHash = await _keyStorage.getPinHash();
    final storedSalt = await _keyStorage.getPinSalt();

    if (storedHash == null || storedSalt == null) return false;

    final parsedHash = _parseStoredHash(storedHash);
    if (parsedHash == null) return false;

    final salt = base64Decode(storedSalt);
    final hash = await _hashPin(
      pin,
      Uint8List.fromList(salt),
      parsedHash.profile,
    );
    final valid = _constantTimeEquals(hash.hash, parsedHash.hash);
    if (valid) {
      final storedLength = await _keyStorage.getPinLength();
      if (parsedHash.profile.id != _preferredProfile.id) {
        unawaited(
          _upgradeStoredHash(
            pin: pin,
            salt: Uint8List.fromList(salt),
            storedSalt: storedSalt,
            expectedStoredHash: storedHash,
          ),
        );
      } else if (storedLength == null) {
        await _keyStorage.storePinLength(pin.length);
      }
    }
    return valid;
  }

  /// Check if PIN is configured
  Future<bool> isPinSetup() async {
    await _keyStorage.initialize();
    return await _keyStorage.hasPinSetup();
  }

  /// Return configured PIN length. Legacy PINs may not have this saved yet.
  Future<int?> getPinLength() async {
    await _keyStorage.initialize();
    return await _keyStorage.getPinLength();
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

  _PinHash? _parseStoredHash(String storedHash) {
    final parts = storedHash.split(r'$');
    if (parts.length == 3 && parts[0] == _storedHashVersion) {
      final profile = _profileForId(parts[1]);
      if (profile == null || parts[2].isEmpty) return null;
      return _PinHash(profile: profile, hash: parts[2]);
    }

    if (storedHash.startsWith('$_storedHashVersion\$')) {
      return null;
    }

    // Legacy hashes were raw Argon2id base64 strings with no profile metadata.
    return _PinHash(
      profile: _nativeProfile,
      hash: storedHash,
    );
  }

  _PinHashProfile? _profileForId(String id) {
    if (id == _nativeProfile.id) return _nativeProfile;
    if (id == _webProfile.id) return _webProfile;
    return null;
  }

  bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;

    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return difference == 0;
  }

  Future<void> _upgradeStoredHash({
    required String pin,
    required Uint8List salt,
    required String storedSalt,
    required String expectedStoredHash,
  }) async {
    try {
      final upgradedHash = await _hashPin(pin, salt, _preferredProfile);
      final currentHash = await _keyStorage.getPinHash();
      if (currentHash != expectedStoredHash) return;

      await _keyStorage.storePinHash(
        upgradedHash.toStorageValue(),
        storedSalt,
        length: pin.length,
      );
    } catch (e) {
      debugPrint('[PinAuth] PIN hash migration skipped: $e');
    }
  }
}

enum _PinHashAlgorithm {
  argon2id,
  pbkdf2Sha256,
}

class _PinHashProfile {
  static const nativeArgonMemory = 65536; // 64 MB
  static const nativeArgonIterations = 3;
  static const nativeArgonParallelism = 2;
  static const webPbkdf2Iterations = 210000;

  final String id;
  final _PinHashAlgorithm algorithm;
  final int memory;
  final int iterations;
  final int parallelism;
  final int hashLength;
  final int bits;

  const _PinHashProfile._({
    required this.id,
    required this.algorithm,
    required this.memory,
    required this.iterations,
    required this.parallelism,
    required this.hashLength,
    required this.bits,
  });

  factory _PinHashProfile.nativeArgon2id({
    int memory = nativeArgonMemory,
    int iterations = nativeArgonIterations,
    int parallelism = nativeArgonParallelism,
  }) {
    return _PinHashProfile._(
      id: 'argon2id-v1',
      algorithm: _PinHashAlgorithm.argon2id,
      memory: memory,
      iterations: iterations,
      parallelism: parallelism,
      hashLength: 32,
      bits: 0,
    );
  }

  factory _PinHashProfile.webPbkdf2({
    int iterations = webPbkdf2Iterations,
  }) {
    return _PinHashProfile._(
      id: 'pbkdf2-sha256-web-v1',
      algorithm: _PinHashAlgorithm.pbkdf2Sha256,
      memory: 0,
      iterations: iterations,
      parallelism: 0,
      hashLength: 32,
      bits: 256,
    );
  }
}

class _PinHash {
  final _PinHashProfile profile;
  final String hash;

  const _PinHash({
    required this.profile,
    required this.hash,
  });

  String toStorageValue() {
    return [
      PinAuth._storedHashVersion,
      profile.id,
      hash,
    ].join(r'$');
  }
}
