import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import '../../utils/constants.dart';
import 'dart:math';

/// Core cryptography manager for GitVault
/// Handles XChaCha20-Poly1305 encryption, HMAC, and padding
class CryptoManager {
  final Xchacha20 _xchacha20 = Xchacha20.poly1305Aead();
  final Random _random = Random.secure();

  /// Encrypts data using XChaCha20-Poly1305
  /// Returns an EncryptedBox containing nonce, ciphertext, and MAC
  Future<EncryptedBox> encryptXChaCha20({
    required Uint8List data,
    required Uint8List key,
  }) async {
    if (key.length != Constants.keySize) {
      throw ArgumentError('Key must be ${Constants.keySize} bytes');
    }

    final secretKey = SecretKey(key);
    final nonce = _generateNonce();

    final secretBox = await _xchacha20.encrypt(
      data,
      secretKey: secretKey,
      nonce: nonce,
    );

    return EncryptedBox(
      nonce: Uint8List.fromList(secretBox.nonce),
      ciphertext: Uint8List.fromList(secretBox.cipherText),
      mac: Uint8List.fromList(secretBox.mac.bytes),
    );
  }

  /// Decrypts data using XChaCha20-Poly1305
  /// Throws if MAC verification fails (tampered data)
  Future<Uint8List> decryptXChaCha20({
    required EncryptedBox box,
    required Uint8List key,
  }) async {
    if (key.length != Constants.keySize) {
      throw ArgumentError('Key must be ${Constants.keySize} bytes');
    }

    final secretKey = SecretKey(key);

    final secretBox = SecretBox(
      box.ciphertext,
      nonce: box.nonce,
      mac: Mac(box.mac),
    );

    try {
      final decrypted = await _xchacha20.decrypt(
        secretBox,
        secretKey: secretKey,
      );
      return Uint8List.fromList(decrypted);
    } catch (e) {
      throw CryptoException('Decryption failed: MAC verification error');
    }
  }

  /// Generates HMAC-SHA256 for filename obfuscation
  /// Deterministic: same input always produces same hash
  Future<String> hmacSha256({
    required Uint8List key,
    required String data,
  }) async {
    final hmac = Hmac.sha256();
    final mac = await hmac.calculateMac(
      utf8.encode(data),
      secretKey: SecretKey(key),
    );

    return mac.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Adds random padding to reach the nearest block size
  /// Format: [4-byte length][actual data][random padding]
  Uint8List addRandomPadding(Uint8List data, {int blockSize = Constants.blockSize}) {
    final dataLength = data.length;
    final headerSize = 4; // 4 bytes for length prefix
    final totalSize = headerSize + dataLength;

    // Calculate padded size (round up to nearest block)
    final paddedSize = ((totalSize + blockSize - 1) ~/ blockSize) * blockSize;

    final result = Uint8List(paddedSize);
    final buffer = ByteData.view(result.buffer);

    // Write length prefix (4 bytes, big-endian)
    buffer.setUint32(0, dataLength, Endian.big);

    // Write actual data
    result.setRange(headerSize, headerSize + dataLength, data);

    // Fill remaining with random padding
    for (int i = headerSize + dataLength; i < paddedSize; i++) {
      result[i] = _random.nextInt(256);
    }

    return result;
  }

  /// Removes padding and extracts original data
  /// Reads the length prefix and returns only the actual data
  Uint8List removeRandomPadding(Uint8List paddedData) {
    if (paddedData.length < 4) {
      throw CryptoException('Invalid padded data: too short');
    }

    final buffer = ByteData.view(paddedData.buffer);
    final dataLength = buffer.getUint32(0, Endian.big);

    if (dataLength + 4 > paddedData.length) {
      throw CryptoException('Invalid padded data: length mismatch');
    }

    return paddedData.sublist(4, 4 + dataLength);
  }

  /// Generates a random 24-byte nonce for XChaCha20
  Uint8List _generateNonce() {
    final nonce = Uint8List(Constants.nonceSize);
    for (int i = 0; i < nonce.length; i++) {
      nonce[i] = _random.nextInt(256);
    }
    return nonce;
  }

  /// Generates a random 256-bit key
  Uint8List generateRandomKey() {
    final key = Uint8List(Constants.keySize);
    for (int i = 0; i < key.length; i++) {
      key[i] = _random.nextInt(256);
    }
    return key;
  }
}

/// Container for encrypted data with nonce and MAC
class EncryptedBox {
  final Uint8List nonce;
  final Uint8List ciphertext;
  final Uint8List mac;

  EncryptedBox({
    required this.nonce,
    required this.ciphertext,
    required this.mac,
  });

  /// Serializes to binary format: [nonce][mac][ciphertext]
  Uint8List toBytes() {
    final result = Uint8List(nonce.length + mac.length + ciphertext.length);
    result.setRange(0, nonce.length, nonce);
    result.setRange(nonce.length, nonce.length + mac.length, mac);
    result.setRange(nonce.length + mac.length, result.length, ciphertext);
    return result;
  }

  /// Deserializes from binary format
  static EncryptedBox fromBytes(Uint8List bytes) {
    if (bytes.length < Constants.nonceSize + Constants.macSize) {
      throw CryptoException('Invalid encrypted box: too short');
    }

    final nonce = bytes.sublist(0, Constants.nonceSize);
    final mac = bytes.sublist(Constants.nonceSize, Constants.nonceSize + Constants.macSize);
    final ciphertext = bytes.sublist(Constants.nonceSize + Constants.macSize);

    return EncryptedBox(nonce: nonce, mac: mac, ciphertext: ciphertext);
  }
}

/// Custom exception for cryptography errors
class CryptoException implements Exception {
  final String message;
  CryptoException(this.message);

  @override
  String toString() => 'CryptoException: $message';
}
