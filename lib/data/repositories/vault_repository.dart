import 'dart:convert';
import 'dart:typed_data';
import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';
import '../../core/crypto/crypto_manager.dart';
import '../../core/crypto/key_storage.dart';
import '../models/vault_entry.dart';

/// Orchestrates encryption and local storage of vault entries
class VaultRepository {
  final CryptoManager _cryptoManager;
  final KeyStorage _keyStorage;
  final Uuid _uuid = const Uuid();

  late Box<String> _localVaultBox;
  bool _isInitialized = false;

  VaultRepository({
    required CryptoManager cryptoManager,
    required KeyStorage keyStorage,
  })  : _cryptoManager = cryptoManager,
        _keyStorage = keyStorage;

  /// Initialize the local vault storage
  Future<void> initialize() async {
    if (_isInitialized) return;

    _localVaultBox = await Hive.openBox<String>('vault_entries');
    _isInitialized = true;
  }

  /// Creates a new vault entry
  Future<VaultEntry> createEntry({
    required String title,
    required String username,
    required String password,
    String? url,
    String? totpSecret,
    String? notes,
    List<String> tags = const [],
  }) async {
    final now = DateTime.now();
    final entry = VaultEntry(
      uuid: _uuid.v4(),
      title: title,
      username: username,
      password: password,
      url: url,
      totpSecret: totpSecret,
      notes: notes,
      createdAt: now,
      modifiedAt: now,
      tags: tags,
    );

    await saveEntry(entry);
    return entry;
  }

  /// Saves a vault entry (encrypt and store locally)
  Future<void> saveEntry(VaultEntry entry) async {
    if (!_isInitialized) {
      throw StateError('VaultRepository not initialized');
    }

    // Get Root Key from secure storage
    final rootKey = await _keyStorage.getRootKey();
    if (rootKey == null) {
      throw StateError('No root key found. User must set up vault first.');
    }

    // Serialize entry to JSON
    final jsonString = entry.toJsonString();
    final jsonBytes = utf8.encode(jsonString);

    // Add padding to obfuscate size
    final paddedBytes = _cryptoManager.addRandomPadding(Uint8List.fromList(jsonBytes));

    // Encrypt
    final encryptedBox = await _cryptoManager.encryptXChaCha20(
      data: paddedBytes,
      key: rootKey,
    );

    // Serialize encrypted box to bytes
    final encryptedBytes = encryptedBox.toBytes();

    // Store locally using UUID as key
    // Store as base64 to avoid Hive serialization issues with raw bytes
    final base64Encoded = base64Encode(encryptedBytes);
    await _localVaultBox.put(entry.uuid, base64Encoded);
  }

  /// Retrieves a vault entry by UUID
  Future<VaultEntry?> getEntry(String uuid) async {
    if (!_isInitialized) {
      throw StateError('VaultRepository not initialized');
    }

    final base64Encoded = _localVaultBox.get(uuid);
    if (base64Encoded == null) return null;

    // Get Root Key
    final rootKey = await _keyStorage.getRootKey();
    if (rootKey == null) {
      throw StateError('No root key found');
    }

    // Decode from base64
    final encryptedBytes = base64Decode(base64Encoded);

    // Deserialize encrypted box
    final encryptedBox = EncryptedBox.fromBytes(encryptedBytes);

    // Decrypt
    final decryptedPadded = await _cryptoManager.decryptXChaCha20(
      box: encryptedBox,
      key: rootKey,
    );

    // Remove padding
    final decryptedBytes = _cryptoManager.removeRandomPadding(decryptedPadded);

    // Parse JSON
    final jsonString = utf8.decode(decryptedBytes);
    final json = jsonDecode(jsonString) as Map<String, dynamic>;

    return VaultEntry.fromJson(json);
  }

  /// Retrieves all vault entries
  Future<List<VaultEntry>> getAllEntries() async {
    if (!_isInitialized) {
      throw StateError('VaultRepository not initialized');
    }

    final entries = <VaultEntry>[];

    for (final uuid in _localVaultBox.keys) {
      final entry = await getEntry(uuid as String);
      if (entry != null) {
        entries.add(entry);
      }
    }

    // Sort by modified date (newest first)
    entries.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));

    return entries;
  }

  /// Updates an existing entry
  Future<void> updateEntry(VaultEntry entry) async {
    final updatedEntry = entry.copyWith(modifiedAt: DateTime.now());
    await saveEntry(updatedEntry);
  }

  /// Deletes an entry
  Future<void> deleteEntry(String uuid) async {
    if (!_isInitialized) {
      throw StateError('VaultRepository not initialized');
    }

    await _localVaultBox.delete(uuid);
  }

  /// Search entries by title, username, or URL
  Future<List<VaultEntry>> searchEntries(String query) async {
    final allEntries = await getAllEntries();
    final lowerQuery = query.toLowerCase();

    return allEntries.where((entry) {
      return entry.title.toLowerCase().contains(lowerQuery) ||
          entry.username.toLowerCase().contains(lowerQuery) ||
          (entry.url?.toLowerCase().contains(lowerQuery) ?? false) ||
          entry.tags.any((tag) => tag.toLowerCase().contains(lowerQuery));
    }).toList();
  }

  /// Get entry count
  Future<int> getEntryCount() async {
    if (!_isInitialized) {
      throw StateError('VaultRepository not initialized');
    }

    return _localVaultBox.length;
  }

  /// Clear all entries (dangerous!)
  Future<void> clearAllEntries() async {
    if (!_isInitialized) {
      throw StateError('VaultRepository not initialized');
    }

    await _localVaultBox.clear();
  }

  /// Close the vault (cleanup)
  Future<void> close() async {
    if (_isInitialized) {
      await _localVaultBox.close();
      _isInitialized = false;
    }
  }
}
