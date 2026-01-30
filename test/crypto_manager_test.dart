import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitvault/core/crypto/crypto_manager.dart';
import 'package:gitvault/utils/constants.dart';

void main() {
  late CryptoManager cryptoManager;

  setUp(() {
    cryptoManager = CryptoManager();
  });

  group('CryptoManager - Encryption/Decryption', () {
    test('should encrypt and decrypt data correctly', () async {
      // Arrange
      final key = cryptoManager.generateRandomKey();
      final plaintext = utf8.encode('Hello, GitVault!');

      // Act
      final encrypted = await cryptoManager.encryptXChaCha20(
        data: Uint8List.fromList(plaintext),
        key: key,
      );

      final decrypted = await cryptoManager.decryptXChaCha20(
        box: encrypted,
        key: key,
      );

      // Assert
      expect(decrypted, equals(plaintext));
      expect(utf8.decode(decrypted), equals('Hello, GitVault!'));
    });

    test('should fail decryption with wrong key', () async {
      // Arrange
      final key1 = cryptoManager.generateRandomKey();
      final key2 = cryptoManager.generateRandomKey();
      final plaintext = utf8.encode('Secret data');

      // Act
      final encrypted = await cryptoManager.encryptXChaCha20(
        data: Uint8List.fromList(plaintext),
        key: key1,
      );

      // Assert
      expect(
        () async => await cryptoManager.decryptXChaCha20(
          box: encrypted,
          key: key2,
        ),
        throwsA(isA<CryptoException>()),
      );
    });

    test('should fail decryption with tampered ciphertext', () async {
      // Arrange
      final key = cryptoManager.generateRandomKey();
      final plaintext = utf8.encode('Important data');

      // Act
      final encrypted = await cryptoManager.encryptXChaCha20(
        data: Uint8List.fromList(plaintext),
        key: key,
      );

      // Tamper with ciphertext
      final tamperedCiphertext = Uint8List.fromList(encrypted.ciphertext);
      tamperedCiphertext[0] ^= 1; // Flip one bit

      final tamperedBox = EncryptedBox(
        nonce: encrypted.nonce,
        ciphertext: tamperedCiphertext,
        mac: encrypted.mac,
      );

      // Assert
      expect(
        () async => await cryptoManager.decryptXChaCha20(
          box: tamperedBox,
          key: key,
        ),
        throwsA(isA<CryptoException>()),
      );
    });

    test('should produce different ciphertexts for same plaintext', () async {
      // Arrange
      final key = cryptoManager.generateRandomKey();
      final plaintext = utf8.encode('Same text');

      // Act
      final encrypted1 = await cryptoManager.encryptXChaCha20(
        data: Uint8List.fromList(plaintext),
        key: key,
      );

      final encrypted2 = await cryptoManager.encryptXChaCha20(
        data: Uint8List.fromList(plaintext),
        key: key,
      );

      // Assert - Different nonces should produce different ciphertexts
      expect(encrypted1.nonce, isNot(equals(encrypted2.nonce)));
      expect(encrypted1.ciphertext, isNot(equals(encrypted2.ciphertext)));
    });
  });

  group('CryptoManager - Padding', () {
    test('should add and remove padding correctly', () async {
      // Arrange
      final data = utf8.encode('Test data for padding');

      // Act
      final padded = cryptoManager.addRandomPadding(
        Uint8List.fromList(data),
      );

      final unpadded = cryptoManager.removeRandomPadding(padded);

      // Assert
      expect(unpadded, equals(data));
      expect(utf8.decode(unpadded), equals('Test data for padding'));
    });

    test('should pad to nearest block size', () async {
      // Arrange
      final smallData = utf8.encode('Hi');
      final blockSize = Constants.blockSize;

      // Act
      final padded = cryptoManager.addRandomPadding(
        Uint8List.fromList(smallData),
        blockSize: blockSize,
      );

      // Assert
      expect(padded.length % blockSize, equals(0));
      expect(padded.length, equals(blockSize)); // Should be exactly one block
    });

    test('should pad large data to multiple blocks', () async {
      // Arrange
      final largeData = Uint8List(5000); // 5KB
      final blockSize = Constants.blockSize;

      // Act
      final padded = cryptoManager.addRandomPadding(largeData, blockSize: blockSize);

      // Assert
      expect(padded.length % blockSize, equals(0));
      expect(padded.length, greaterThanOrEqualTo(5000 + 4)); // data + length prefix
    });

    test('should handle empty data', () async {
      // Arrange
      final emptyData = Uint8List(0);

      // Act
      final padded = cryptoManager.addRandomPadding(emptyData);
      final unpadded = cryptoManager.removeRandomPadding(padded);

      // Assert
      expect(unpadded.length, equals(0));
    });
  });

  group('CryptoManager - HMAC', () {
    test('should generate deterministic HMAC', () async {
      // Arrange
      final key = cryptoManager.generateRandomKey();
      final data = 'test-uuid-12345';

      // Act
      final hmac1 = await cryptoManager.hmacSha256(key: key, data: data);
      final hmac2 = await cryptoManager.hmacSha256(key: key, data: data);

      // Assert
      expect(hmac1, equals(hmac2));
      expect(hmac1.length, equals(64)); // SHA256 = 32 bytes = 64 hex chars
    });

    test('should produce different HMACs for different inputs', () async {
      // Arrange
      final key = cryptoManager.generateRandomKey();

      // Act
      final hmac1 = await cryptoManager.hmacSha256(key: key, data: 'uuid-1');
      final hmac2 = await cryptoManager.hmacSha256(key: key, data: 'uuid-2');

      // Assert
      expect(hmac1, isNot(equals(hmac2)));
    });

    test('should produce different HMACs with different keys', () async {
      // Arrange
      final key1 = cryptoManager.generateRandomKey();
      final key2 = cryptoManager.generateRandomKey();
      final data = 'same-uuid';

      // Act
      final hmac1 = await cryptoManager.hmacSha256(key: key1, data: data);
      final hmac2 = await cryptoManager.hmacSha256(key: key2, data: data);

      // Assert
      expect(hmac1, isNot(equals(hmac2)));
    });
  });

  group('CryptoManager - EncryptedBox Serialization', () {
    test('should serialize and deserialize EncryptedBox', () async {
      // Arrange
      final key = cryptoManager.generateRandomKey();
      final plaintext = utf8.encode('Serialization test');

      // Act
      final encrypted = await cryptoManager.encryptXChaCha20(
        data: Uint8List.fromList(plaintext),
        key: key,
      );

      final bytes = encrypted.toBytes();
      final deserialized = EncryptedBox.fromBytes(bytes);

      final decrypted = await cryptoManager.decryptXChaCha20(
        box: deserialized,
        key: key,
      );

      // Assert
      expect(deserialized.nonce, equals(encrypted.nonce));
      expect(deserialized.mac, equals(encrypted.mac));
      expect(deserialized.ciphertext, equals(encrypted.ciphertext));
      expect(decrypted, equals(plaintext));
    });
  });

  group('CryptoManager - Key Generation', () {
    test('should generate 256-bit keys', () {
      // Act
      final key = cryptoManager.generateRandomKey();

      // Assert
      expect(key.length, equals(Constants.keySize));
      expect(key.length, equals(32)); // 256 bits = 32 bytes
    });

    test('should generate unique keys', () {
      // Act
      final key1 = cryptoManager.generateRandomKey();
      final key2 = cryptoManager.generateRandomKey();

      // Assert
      expect(key1, isNot(equals(key2)));
    });
  });

  group('CryptoManager - Full Integration', () {
    test('should encrypt, pad, serialize, deserialize, unpad, decrypt', () async {
      // Arrange
      final key = cryptoManager.generateRandomKey();
      final originalData = utf8.encode('Full integration test with padding');

      // Act - Full pipeline
      // 1. Add padding
      final padded = cryptoManager.addRandomPadding(Uint8List.fromList(originalData));

      // 2. Encrypt
      final encrypted = await cryptoManager.encryptXChaCha20(
        data: padded,
        key: key,
      );

      // 3. Serialize
      final bytes = encrypted.toBytes();

      // Simulate storage/transfer
      // ...

      // 4. Deserialize
      final deserialized = EncryptedBox.fromBytes(bytes);

      // 5. Decrypt
      final decrypted = await cryptoManager.decryptXChaCha20(
        box: deserialized,
        key: key,
      );

      // 6. Remove padding
      final unpadded = cryptoManager.removeRandomPadding(decrypted);

      // Assert
      expect(unpadded, equals(originalData));
      expect(utf8.decode(unpadded), equals('Full integration test with padding'));
    });
  });
}
