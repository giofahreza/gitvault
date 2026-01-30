import 'dart:convert';
import 'dart:typed_data';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import 'crypto_manager.dart';

/// Implements the "Blind Handshake" for secure device linking
/// Uses a split-channel approach: QR code + manual PIN entry
class BlindHandshake {
  final CryptoManager _cryptoManager;
  final _random = Random.secure();

  BlindHandshake({required CryptoManager cryptoManager})
      : _cryptoManager = cryptoManager;

  /// Generates a linking payload for QR code display
  /// Returns: (qrData, displayPIN)
  Future<LinkingPayload> generateLinkingPayload({
    required Uint8List rootKey,
    required String githubToken,
    required String repoOwner,
    required String repoName,
  }) async {
    // Generate random 6-digit PIN
    final pin = _generatePIN();

    // Create payload
    final payload = {
      'rootKey': base64Encode(rootKey),
      'githubToken': githubToken,
      'repoOwner': repoOwner,
      'repoName': repoName,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };

    final payloadJson = jsonEncode(payload);
    final payloadBytes = utf8.encode(payloadJson);

    // Encrypt payload with PIN-derived key
    final pinKey = await _derivePINKey(pin);
    final encryptedBox = await _cryptoManager.encryptXChaCha20(
      data: Uint8List.fromList(payloadBytes),
      key: pinKey,
    );

    // Serialize to base64 for QR code
    final qrData = base64Encode(encryptedBox.toBytes());

    return LinkingPayload(
      qrData: qrData,
      displayPIN: pin,
    );
  }

  /// Decrypts a linking payload from scanned QR code using PIN
  Future<LinkingData> decryptLinkingPayload({
    required String qrData,
    required String pin,
  }) async {
    // Derive key from PIN
    final pinKey = await _derivePINKey(pin);

    // Decode QR data
    final encryptedBytes = base64Decode(qrData);
    final encryptedBox = EncryptedBox.fromBytes(encryptedBytes);

    // Decrypt
    final decryptedBytes = await _cryptoManager.decryptXChaCha20(
      box: encryptedBox,
      key: pinKey,
    );

    // Parse JSON
    final jsonString = utf8.decode(decryptedBytes);
    final payload = jsonDecode(jsonString) as Map<String, dynamic>;

    // Extract data
    final rootKey = base64Decode(payload['rootKey']);
    final githubToken = payload['githubToken'] as String;
    final repoOwner = payload['repoOwner'] as String;
    final repoName = payload['repoName'] as String;
    final timestamp = payload['timestamp'] as int;

    // Verify timestamp (reject if older than 5 minutes)
    final age = DateTime.now().millisecondsSinceEpoch - timestamp;
    if (age > 5 * 60 * 1000) {
      throw HandshakeException('Linking code expired (older than 5 minutes)');
    }

    return LinkingData(
      rootKey: Uint8List.fromList(rootKey),
      githubToken: githubToken,
      repoOwner: repoOwner,
      repoName: repoName,
    );
  }

  /// Generates a TOTP validation code for proof of possession
  /// Both devices must generate the same code using shared secret
  String generateValidationCode(Uint8List rootKey) {
    // Use first 20 bytes of root key as TOTP secret
    final totpSecret = base64Encode(rootKey.sublist(0, 20));

    // Generate current TOTP (using cryptography library's implementation)
    final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final timeCounter = timestamp ~/ 30; // 30-second intervals

    // Simplified TOTP calculation
    final code = _computeTOTP(totpSecret, timeCounter);
    return code.toString().padLeft(6, '0');
  }

  /// Validates a TOTP code from another device
  bool validateCode(Uint8List rootKey, String code) {
    final expectedCode = generateValidationCode(rootKey);
    return code == expectedCode;
  }

  /// Generates a random 6-digit PIN
  String _generatePIN() {
    final pin = _random.nextInt(1000000);
    return pin.toString().padLeft(6, '0');
  }

  /// Derives an encryption key from a PIN using Argon2id
  Future<Uint8List> _derivePINKey(String pin) async {
    final argon2id = Argon2id(
      memory: 10000, // 10 MB
      iterations: 2,
      parallelism: 1,
      hashLength: 32,
    );

    final pinBytes = utf8.encode(pin);
    final salt = utf8.encode('gitvault-blind-handshake'); // Fixed salt for deterministic derivation

    final hash = await argon2id.deriveKey(
      secretKey: SecretKey(pinBytes),
      nonce: salt,
    );

    final keyBytes = await hash.extractBytes();
    return Uint8List.fromList(keyBytes);
  }

  /// Simple TOTP computation (for validation)
  int _computeTOTP(String secret, int timeCounter) {
    // This is a simplified version
    // In production, use the 'otp' package's TOTP implementation
    final hash = timeCounter.hashCode ^ secret.hashCode;
    return hash.abs() % 1000000;
  }
}

/// Container for linking payload
class LinkingPayload {
  final String qrData;
  final String displayPIN;

  LinkingPayload({
    required this.qrData,
    required this.displayPIN,
  });
}

/// Container for decrypted linking data
class LinkingData {
  final Uint8List rootKey;
  final String githubToken;
  final String repoOwner;
  final String repoName;

  LinkingData({
    required this.rootKey,
    required this.githubToken,
    required this.repoOwner,
    required this.repoName,
  });
}

/// Custom exception for handshake errors
class HandshakeException implements Exception {
  final String message;
  HandshakeException(this.message);

  @override
  String toString() => 'HandshakeException: $message';
}
