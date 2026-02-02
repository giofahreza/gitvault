import 'dart:convert';
import 'dart:typed_data';
import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';

import '../../core/crypto/crypto_manager.dart';
import '../../core/crypto/key_storage.dart';
import '../models/ssh_credential.dart';

/// Repository for managing encrypted SSH credentials
class SshRepository {
  final CryptoManager _cryptoManager;
  final KeyStorage _keyStorage;
  final Uuid _uuid = const Uuid();

  late Box<String> _sshBox;
  bool _isInitialized = false;

  SshRepository({
    required CryptoManager cryptoManager,
    required KeyStorage keyStorage,
  })  : _cryptoManager = cryptoManager,
        _keyStorage = keyStorage;

  /// Initialize the SSH credentials storage
  Future<void> initialize() async {
    if (_isInitialized) return;
    _sshBox = await Hive.openBox<String>('ssh_credentials');
    _isInitialized = true;
  }

  /// Create a new SSH credential
  Future<SshCredential> createCredential({
    required String label,
    required String host,
    int port = 22,
    required String username,
    SshAuthType authType = SshAuthType.password,
    String password = '',
    String privateKey = '',
    String passphrase = '',
  }) async {
    final now = DateTime.now();
    final credential = SshCredential(
      uuid: _uuid.v4(),
      label: label,
      host: host,
      port: port,
      username: username,
      authType: authType,
      password: password,
      privateKey: privateKey,
      passphrase: passphrase,
      createdAt: now,
      modifiedAt: now,
    );

    await _saveCredential(credential);
    return credential;
  }

  /// Update an existing SSH credential
  Future<void> updateCredential(SshCredential credential) async {
    final updated = credential.copyWith(modifiedAt: DateTime.now());
    await _saveCredential(updated);
  }

  /// Delete an SSH credential
  Future<void> deleteCredential(String uuid) async {
    if (!_isInitialized) {
      throw StateError('SshRepository not initialized');
    }
    await _sshBox.delete(uuid);
  }

  /// Save a credential (for sync engine)
  Future<void> saveCredential(SshCredential credential) async {
    await _saveCredential(credential);
  }

  /// Get a single SSH credential by UUID
  Future<SshCredential?> getCredential(String uuid) async {
    if (!_isInitialized) {
      throw StateError('SshRepository not initialized');
    }

    final base64Encoded = _sshBox.get(uuid);
    if (base64Encoded == null) return null;

    final rootKey = await _keyStorage.getRootKey();
    if (rootKey == null) {
      throw StateError('No root key found');
    }

    final encryptedBytes = base64Decode(base64Encoded);
    final encryptedBox = EncryptedBox.fromBytes(encryptedBytes);
    final decryptedPadded = await _cryptoManager.decryptXChaCha20(
      box: encryptedBox,
      key: rootKey,
    );
    final decryptedBytes = _cryptoManager.removeRandomPadding(decryptedPadded);
    final jsonString = utf8.decode(decryptedBytes);
    final json = jsonDecode(jsonString) as Map<String, dynamic>;

    return SshCredential.fromJson(json);
  }

  /// Get all SSH credentials
  Future<List<SshCredential>> getAllCredentials() async {
    if (!_isInitialized) {
      throw StateError('SshRepository not initialized');
    }

    final credentials = <SshCredential>[];
    for (final uuid in _sshBox.keys) {
      try {
        final credential = await getCredential(uuid as String);
        if (credential != null) {
          credentials.add(credential);
        }
      } catch (e) {
        // Skip corrupted credentials
      }
    }

    // Sort by modified date (newest first)
    credentials.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));

    return credentials;
  }

  Future<void> _saveCredential(SshCredential credential) async {
    if (!_isInitialized) {
      throw StateError('SshRepository not initialized');
    }

    final rootKey = await _keyStorage.getRootKey();
    if (rootKey == null) {
      throw StateError('No root key found. User must set up vault first.');
    }

    final jsonString = credential.toJsonString();
    final jsonBytes = utf8.encode(jsonString);
    final paddedBytes = _cryptoManager.addRandomPadding(Uint8List.fromList(jsonBytes));
    final encryptedBox = await _cryptoManager.encryptXChaCha20(
      data: paddedBytes,
      key: rootKey,
    );
    final encryptedBytes = encryptedBox.toBytes();
    final base64Encoded = base64Encode(encryptedBytes);

    await _sshBox.put(credential.uuid, base64Encoded);
  }

  /// Close the SSH box
  Future<void> close() async {
    if (_isInitialized) {
      await _sshBox.close();
      _isInitialized = false;
    }
  }
}
