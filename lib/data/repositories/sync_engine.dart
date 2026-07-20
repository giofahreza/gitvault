import 'dart:convert';
import 'dart:typed_data';
import 'package:hive/hive.dart';
import '../../core/crypto/crypto_manager.dart';
import '../../core/crypto/key_storage.dart';
import '../../core/services/github_service.dart';
import '../../utils/constants.dart';
import '../models/vault_entry.dart';
import '../models/note.dart';
import '../models/ssh_credential.dart';
import '../models/sync_index.dart';
import 'vault_repository.dart';
import 'notes_repository.dart';
import 'ssh_repository.dart';
import '../../core/services/device_identity_service.dart';

/// Manages synchronization between local vault and GitHub storage
/// Implements "Smart Sync" with conflict resolution via Last Write Wins
/// Syncs both password entries and notes to the same GitHub data folder
class SyncEngine {
  static Future<SyncResult>? _activeSync;

  final VaultRepository _vaultRepository;
  final NotesRepository _notesRepository;
  final SshRepository? _sshRepository;
  final GitHubService _githubService;
  final CryptoManager _cryptoManager;
  final KeyStorage _keyStorage;

  late Box<String> _syncMetadataBox;
  bool _isInitialized = false;
  SyncIndex? _lastRemoteIndex;
  final Set<String> _remoteItemsNeedingRepair = <String>{};

  SyncEngine({
    required VaultRepository vaultRepository,
    required NotesRepository notesRepository,
    SshRepository? sshRepository,
    required GitHubService githubService,
    required CryptoManager cryptoManager,
    required KeyStorage keyStorage,
  })  : _vaultRepository = vaultRepository,
        _notesRepository = notesRepository,
        _sshRepository = sshRepository,
        _githubService = githubService,
        _cryptoManager = cryptoManager,
        _keyStorage = keyStorage;

  /// Initialize sync engine
  Future<void> initialize() async {
    if (_isInitialized) return;

    _syncMetadataBox = await Hive.openBox<String>('sync_metadata');
    await _vaultRepository.initialize();
    await _notesRepository.initialize();
    await _sshRepository?.initialize();
    _isInitialized = true;
  }

  /// Performs full sync: pull from GitHub then push local changes
  Future<SyncResult> sync() async {
    // Several screens can request a foreground sync at the same time. Sharing
    // one in-flight operation prevents them from racing to rewrite the GitHub
    // index with different snapshots.
    final activeSync = _activeSync;
    if (activeSync != null) return activeSync;

    late final Future<SyncResult> operation;
    operation = _performSync().whenComplete(() {
      if (identical(_activeSync, operation)) {
        _activeSync = null;
      }
    });
    _activeSync = operation;
    return operation;
  }

  Future<SyncResult> _performSync() async {
    if (!_isInitialized) {
      throw StateError('SyncEngine not initialized');
    }

    final rootKey = await _keyStorage.getRootKey();
    if (rootKey == null) {
      throw StateError('No root key found');
    }

    // Pull remote changes first
    final pullResult = await _pullFromGitHub(rootKey);

    // Push local changes
    final pushResult = await _pushToGitHub(rootKey);

    // Sync device registry
    await _syncDeviceRegistry();

    // Record sync time
    await _setLastSyncTime(DateTime.now());

    return SyncResult(
      pulled: pullResult.downloaded,
      pushed: pushResult.uploaded,
      conflicts: pullResult.conflicts,
    );
  }

  /// Pulls entries from GitHub and merges with local
  Future<PullResult> _pullFromGitHub(Uint8List rootKey) async {
    int downloaded = 0;
    int conflicts = 0;

    try {
      _lastRemoteIndex = null;
      _remoteItemsNeedingRepair.clear();

      // Download index file
      final indexBytes = await _githubService.downloadFile(Constants.indexFile);

      if (indexBytes == null) {
        // No index yet, first sync
        return PullResult(downloaded: 0, conflicts: 0);
      }

      // Decrypt index
      final syncIndex = await _decryptIndex(indexBytes, rootKey);
      _lastRemoteIndex = syncIndex;

      // Verify monotonic counter (anti-rollback)
      final localCounter = await _getLocalCounter();
      if (syncIndex.monotonicCounter < localCounter) {
        throw SyncException(
            'Rollback attack detected! Remote counter is lower than local.');
      }

      // Download each item from the map (could be password entry or note)
      for (final entry in syncIndex.uuidToHashMap.entries) {
        final uuid = entry.key;
        final filenameHash = entry.value;
        final remotePath =
            '${Constants.dataFolder}/$filenameHash${Constants.fileExtension}';

        // Download file
        final fileBytes = await _githubService.downloadFile(remotePath);
        if (fileBytes == null) {
          _remoteItemsNeedingRepair.add(uuid);
          continue;
        }

        // Try to decrypt as VaultEntry first, then as Note
        try {
          // Try as password entry
          final remoteEntry = await _decryptEntry(fileBytes, rootKey);

          // Check if we have local version
          final localEntry = await _vaultRepository.getEntry(uuid);

          if (localEntry == null) {
            // New entry, save it
            await _vaultRepository.saveEntry(remoteEntry);
            downloaded++;
          } else {
            // Conflict resolution: Last Write Wins
            if (remoteEntry.modifiedAt.isAfter(localEntry.modifiedAt)) {
              await _vaultRepository.saveEntry(remoteEntry);
              downloaded++;
              conflicts++;
            }
          }
        } catch (_) {
          // Not a vault entry, try as note
          try {
            final remoteNote = await _decryptNote(fileBytes, rootKey);

            // Check if we have local version
            final localNote = await _notesRepository.getNote(uuid);

            if (localNote == null) {
              // It may have been created locally after the read above, so the
              // repository performs one final timestamp check before writing.
              if (await _notesRepository.saveNoteIfNewer(remoteNote)) {
                downloaded++;
              }
            } else {
              // Conflict resolution: Last Write Wins
              if (remoteNote.modifiedAt.isAfter(localNote.modifiedAt) &&
                  await _notesRepository.saveNoteIfNewer(remoteNote)) {
                downloaded++;
                conflicts++;
              }
            }
          } catch (_) {
            // Not a note, try as SSH credential
            try {
              if (_sshRepository != null) {
                final remoteSsh =
                    await _decryptSshCredential(fileBytes, rootKey);

                final localSsh = await _sshRepository!.getCredential(uuid);

                if (localSsh == null) {
                  await _sshRepository!.saveCredential(remoteSsh);
                  downloaded++;
                } else {
                  if (remoteSsh.modifiedAt.isAfter(localSsh.modifiedAt)) {
                    await _sshRepository!.saveCredential(remoteSsh);
                    downloaded++;
                    conflicts++;
                  }
                }
              }
            } catch (e) {
              // Could not decrypt as any type, skip
              _remoteItemsNeedingRepair.add(uuid);
              continue;
            }
          }
        }
      }

      // Update local counter
      await _setLocalCounter(syncIndex.monotonicCounter);

      return PullResult(downloaded: downloaded, conflicts: conflicts);
    } catch (e) {
      throw SyncException('Pull failed: $e');
    }
  }

  /// Pushes local entries and notes to GitHub
  Future<PushResult> _pushToGitHub(Uint8List rootKey) async {
    int uploaded = 0;

    try {
      // Get all local entries (passwords), notes, and SSH credentials
      final entries = await _vaultRepository.getAllEntries();
      final notes = await _notesRepository.getAllStoredNotes();
      final sshCredentials = _sshRepository != null
          ? await _sshRepository!.getAllCredentials()
          : <SshCredential>[];

      // If no local data, check if remote index exists
      if (entries.isEmpty && notes.isEmpty && sshCredentials.isEmpty) {
        final indexBytes =
            await _githubService.downloadFile(Constants.indexFile);
        if (indexBytes == null) {
          // Both local and remote empty - nothing to push
          return PushResult(uploaded: 0);
        }

        // Remote has data but local is empty - already pulled, nothing to push
        return PushResult(uploaded: 0);
      }

      // Build UUID-to-hash map
      // Start with the remote maps. If a single remote item cannot be read, a
      // sync should not silently remove it from the encrypted index.
      final Map<String, String> uuidToHashMap = {
        ...?_lastRemoteIndex?.uuidToHashMap,
      };
      final Map<String, String> uuidToContentHashMap = {
        ...?_lastRemoteIndex?.uuidToContentHashMap,
      };

      // Upload each password entry
      for (final entry in entries) {
        // Generate deterministic filename hash
        final filenameHash = await _cryptoManager.hmacSha256(
          key: rootKey,
          data: entry.uuid,
        );

        uuidToHashMap[entry.uuid] = filenameHash;

        final contentHash = await _contentHash(
          rootKey,
          'vault',
          entry.toJsonString(),
        );
        final isUnchanged = !_remoteItemsNeedingRepair.contains(entry.uuid) &&
            _lastRemoteIndex?.uuidToContentHashMap[entry.uuid] == contentHash;
        uuidToContentHashMap[entry.uuid] = contentHash;

        if (isUnchanged) continue;

        final remotePath =
            '${Constants.dataFolder}/$filenameHash${Constants.fileExtension}';

        // Encrypt entry
        final encryptedBytes = await _encryptEntry(entry, rootKey);

        // Upload to GitHub
        await _githubService.uploadFile(
          path: remotePath,
          content: encryptedBytes,
          commitMessage: Constants.defaultCommitMessage,
        );

        uploaded++;
      }

      // Upload each note
      for (final note in notes) {
        // Generate deterministic filename hash
        final filenameHash = await _cryptoManager.hmacSha256(
          key: rootKey,
          data: note.uuid,
        );

        uuidToHashMap[note.uuid] = filenameHash;

        final contentHash = await _contentHash(
          rootKey,
          'note',
          note.toJsonString(),
        );
        final isUnchanged = !_remoteItemsNeedingRepair.contains(note.uuid) &&
            _lastRemoteIndex?.uuidToContentHashMap[note.uuid] == contentHash;
        uuidToContentHashMap[note.uuid] = contentHash;

        if (isUnchanged) continue;

        final remotePath =
            '${Constants.dataFolder}/$filenameHash${Constants.fileExtension}';

        // Encrypt note
        final encryptedBytes = await _encryptNote(note, rootKey);

        // Upload to GitHub
        await _githubService.uploadFile(
          path: remotePath,
          content: encryptedBytes,
          commitMessage: Constants.defaultCommitMessage,
        );

        uploaded++;
      }

      // Upload each SSH credential
      for (final ssh in sshCredentials) {
        final filenameHash = await _cryptoManager.hmacSha256(
          key: rootKey,
          data: ssh.uuid,
        );

        uuidToHashMap[ssh.uuid] = filenameHash;

        final contentHash = await _contentHash(
          rootKey,
          'ssh',
          ssh.toJsonString(),
        );
        final isUnchanged = !_remoteItemsNeedingRepair.contains(ssh.uuid) &&
            _lastRemoteIndex?.uuidToContentHashMap[ssh.uuid] == contentHash;
        uuidToContentHashMap[ssh.uuid] = contentHash;

        if (isUnchanged) continue;

        final remotePath =
            '${Constants.dataFolder}/$filenameHash${Constants.fileExtension}';

        final encryptedBytes = await _encryptSshCredential(ssh, rootKey);

        await _githubService.uploadFile(
          path: remotePath,
          content: encryptedBytes,
          commitMessage: Constants.defaultCommitMessage,
        );

        uploaded++;
      }

      final remoteIndex = _lastRemoteIndex;
      final indexChanged = remoteIndex == null ||
          !_mapsEqual(remoteIndex.uuidToHashMap, uuidToHashMap) ||
          !_mapsEqual(
            remoteIndex.uuidToContentHashMap,
            uuidToContentHashMap,
          );

      // Do not create a new GitHub commit when the encrypted data set is
      // already current.
      if (!indexChanged) {
        return PushResult(uploaded: uploaded);
      }

      // Create and upload index
      final newCounter = await _getLocalCounter() + 1;
      final syncIndex = SyncIndex(
        lastUpdated: DateTime.now(),
        monotonicCounter: newCounter,
        uuidToHashMap: uuidToHashMap,
        uuidToContentHashMap: uuidToContentHashMap,
      );

      final indexBytes = await _encryptIndex(syncIndex, rootKey);
      await _githubService.uploadFile(
        path: Constants.indexFile,
        content: indexBytes,
        commitMessage: 'Update index',
      );

      // Update local counter
      await _setLocalCounter(newCounter);

      return PushResult(uploaded: uploaded);
    } catch (e) {
      throw SyncException('Push failed: $e');
    }
  }

  Future<String> _contentHash(
    Uint8List rootKey,
    String type,
    String json,
  ) {
    return _cryptoManager.hmacSha256(
      key: rootKey,
      data: '$type:$json',
    );
  }

  bool _mapsEqual(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  /// Syncs the device registry with GitHub
  Future<void> _syncDeviceRegistry() async {
    try {
      await refreshDeviceRegistry(
        keyStorage: _keyStorage,
        cryptoManager: _cryptoManager,
        githubService: _githubService,
        uploadIfNeeded: true,
      );
    } catch (_) {
      // Non-fatal: device registry sync failure should not block vault sync
    }
  }

  /// Rebuilds the device registry from remote state and local device identity.
  /// When [uploadIfNeeded] is false, the merged registry is cached locally only.
  static Future<Map<String, dynamic>?> refreshDeviceRegistry({
    required KeyStorage keyStorage,
    required CryptoManager cryptoManager,
    required GitHubService githubService,
    bool uploadIfNeeded = true,
  }) async {
    await keyStorage.initialize();

    final rootKey = await keyStorage.getRootKey();
    if (rootKey == null) return null;

    final identity =
        await DeviceIdentityService(keyStorage: keyStorage).ensureIdentity();
    final now = DateTime.now();
    final nowIso = now.toIso8601String();

    Map<String, dynamic> registry = {};
    final registryBytes =
        await githubService.downloadFile(Constants.trustedDevicesFile);
    if (registryBytes != null) {
      try {
        final encryptedBox = EncryptedBox.fromBytes(registryBytes);
        final decryptedPadded = await cryptoManager.decryptXChaCha20(
          box: encryptedBox,
          key: rootKey,
        );
        final decryptedBytes =
            cryptoManager.removeRandomPadding(decryptedPadded);
        final jsonString = utf8.decode(decryptedBytes);
        registry = jsonDecode(jsonString) as Map<String, dynamic>;
      } catch (_) {
        // Never replace a registry we could not authenticate or decrypt;
        // doing so could erase the trusted-device list for every client.
        return null;
      }
    }

    final devices = (registry['devices'] as List<dynamic>?) ?? [];
    bool found = false;
    bool needsUpload = false;

    final updatedDevices = devices.map((d) {
      final device = Map<String, dynamic>.from(d as Map);
      if (device['deviceId'] == identity.id) {
        found = true;
        final previousLastSeen =
            DateTime.tryParse(device['lastSeen'] as String? ?? '');
        final lastSeenIsStale = previousLastSeen == null ||
            now.difference(previousLastSeen) >= const Duration(hours: 6);
        final nameChanged = device['name'] != identity.name;

        if (!lastSeenIsStale && !nameChanged) return device;

        needsUpload = true;
        return {
          ...device,
          'name': identity.name,
          'lastSeen': nowIso,
        };
      }
      return device;
    }).toList();

    if (!found) {
      needsUpload = true;
      updatedDevices.add({
        'deviceId': identity.id,
        'name': identity.name,
        'lastSeen': nowIso,
        'addedAt': nowIso,
      });
    }

    registry['devices'] = updatedDevices;
    final registryJson = jsonEncode(registry);

    if (uploadIfNeeded && needsUpload) {
      final jsonBytes = utf8.encode(registryJson);
      final paddedBytes =
          cryptoManager.addRandomPadding(Uint8List.fromList(jsonBytes));
      final encryptedBox = await cryptoManager.encryptXChaCha20(
        data: paddedBytes,
        key: rootKey,
      );

      await githubService.uploadFile(
        path: Constants.trustedDevicesFile,
        content: encryptedBox.toBytes(),
        commitMessage: 'Update device registry',
      );
    }

    await keyStorage.storeDeviceRegistry(registryJson);
    return registry;
  }

  /// Encrypts a vault entry to bytes
  Future<Uint8List> _encryptEntry(VaultEntry entry, Uint8List key) async {
    final jsonString = entry.toJsonString();
    final jsonBytes = utf8.encode(jsonString);
    final paddedBytes =
        _cryptoManager.addRandomPadding(Uint8List.fromList(jsonBytes));

    final encryptedBox = await _cryptoManager.encryptXChaCha20(
      data: paddedBytes,
      key: key,
    );

    return encryptedBox.toBytes();
  }

  /// Decrypts a vault entry from bytes
  Future<VaultEntry> _decryptEntry(Uint8List bytes, Uint8List key) async {
    final encryptedBox = EncryptedBox.fromBytes(bytes);
    final decryptedPadded = await _cryptoManager.decryptXChaCha20(
      box: encryptedBox,
      key: key,
    );

    final decryptedBytes = _cryptoManager.removeRandomPadding(decryptedPadded);
    final jsonString = utf8.decode(decryptedBytes);
    final json = jsonDecode(jsonString) as Map<String, dynamic>;

    return VaultEntry.fromJson(json);
  }

  /// Encrypts a note to bytes
  Future<Uint8List> _encryptNote(Note note, Uint8List key) async {
    final jsonString = jsonEncode(note.toJson());
    final jsonBytes = utf8.encode(jsonString);
    final paddedBytes =
        _cryptoManager.addRandomPadding(Uint8List.fromList(jsonBytes));

    final encryptedBox = await _cryptoManager.encryptXChaCha20(
      data: paddedBytes,
      key: key,
    );

    return encryptedBox.toBytes();
  }

  /// Decrypts a note from bytes
  Future<Note> _decryptNote(Uint8List bytes, Uint8List key) async {
    final encryptedBox = EncryptedBox.fromBytes(bytes);
    final decryptedPadded = await _cryptoManager.decryptXChaCha20(
      box: encryptedBox,
      key: key,
    );

    final decryptedBytes = _cryptoManager.removeRandomPadding(decryptedPadded);
    final jsonString = utf8.decode(decryptedBytes);
    final json = jsonDecode(jsonString) as Map<String, dynamic>;

    return Note.fromJson(json);
  }

  /// Encrypts an SSH credential to bytes
  Future<Uint8List> _encryptSshCredential(
      SshCredential credential, Uint8List key) async {
    final jsonString = jsonEncode(credential.toJson());
    final jsonBytes = utf8.encode(jsonString);
    final paddedBytes =
        _cryptoManager.addRandomPadding(Uint8List.fromList(jsonBytes));

    final encryptedBox = await _cryptoManager.encryptXChaCha20(
      data: paddedBytes,
      key: key,
    );

    return encryptedBox.toBytes();
  }

  /// Decrypts an SSH credential from bytes
  Future<SshCredential> _decryptSshCredential(
      Uint8List bytes, Uint8List key) async {
    final encryptedBox = EncryptedBox.fromBytes(bytes);
    final decryptedPadded = await _cryptoManager.decryptXChaCha20(
      box: encryptedBox,
      key: key,
    );

    final decryptedBytes = _cryptoManager.removeRandomPadding(decryptedPadded);
    final jsonString = utf8.decode(decryptedBytes);
    final json = jsonDecode(jsonString) as Map<String, dynamic>;

    return SshCredential.fromJson(json);
  }

  /// Encrypts the sync index
  Future<Uint8List> _encryptIndex(SyncIndex index, Uint8List key) async {
    final jsonString = jsonEncode(index.toJson());
    final jsonBytes = utf8.encode(jsonString);
    final paddedBytes =
        _cryptoManager.addRandomPadding(Uint8List.fromList(jsonBytes));

    final encryptedBox = await _cryptoManager.encryptXChaCha20(
      data: paddedBytes,
      key: key,
    );

    return encryptedBox.toBytes();
  }

  /// Decrypts the sync index
  Future<SyncIndex> _decryptIndex(Uint8List bytes, Uint8List key) async {
    final encryptedBox = EncryptedBox.fromBytes(bytes);
    final decryptedPadded = await _cryptoManager.decryptXChaCha20(
      box: encryptedBox,
      key: key,
    );

    final decryptedBytes = _cryptoManager.removeRandomPadding(decryptedPadded);
    final jsonString = utf8.decode(decryptedBytes);
    final json = jsonDecode(jsonString) as Map<String, dynamic>;

    return SyncIndex.fromJson(json);
  }

  /// Gets local monotonic counter
  Future<int> _getLocalCounter() async {
    if (!_isInitialized || !_syncMetadataBox.isOpen) {
      return 0;
    }
    final counterStr = _syncMetadataBox.get('monotonic_counter');
    return counterStr != null ? int.parse(counterStr) : 0;
  }

  /// Sets local monotonic counter
  Future<void> _setLocalCounter(int counter) async {
    if (!_isInitialized || !_syncMetadataBox.isOpen) {
      return;
    }
    await _syncMetadataBox.put('monotonic_counter', counter.toString());
  }

  /// Gets last sync timestamp
  Future<DateTime?> getLastSyncTime() async {
    if (!_isInitialized || !_syncMetadataBox.isOpen) {
      return null;
    }
    final timestamp = _syncMetadataBox.get('last_sync');
    return timestamp != null ? DateTime.parse(timestamp) : null;
  }

  /// Sets last sync timestamp
  Future<void> _setLastSyncTime(DateTime time) async {
    if (!_isInitialized || !_syncMetadataBox.isOpen) {
      return;
    }
    await _syncMetadataBox.put('last_sync', time.toIso8601String());
  }

  /// Close sync engine
  /// Note: In most cases, you should NOT call this method as Hive boxes
  /// should remain open for the lifetime of the app. Only call this when
  /// the app is shutting down.
  Future<void> close() async {
    if (_isInitialized && _syncMetadataBox.isOpen) {
      await _syncMetadataBox.close();
      _isInitialized = false;
    }
  }

  /// Disposes resources without closing the Hive box
  /// Use this after sync operations instead of close()
  void dispose() {
    // Don't close the box, just mark as not needing initialization
    // The box will remain open for future sync operations
  }
}

class SyncResult {
  final int pulled;
  final int pushed;
  final int conflicts;

  SyncResult({
    required this.pulled,
    required this.pushed,
    required this.conflicts,
  });
}

class PullResult {
  final int downloaded;
  final int conflicts;

  PullResult({required this.downloaded, required this.conflicts});
}

class PushResult {
  final int uploaded;

  PushResult({required this.uploaded});
}

class SyncException implements Exception {
  final String message;
  SyncException(this.message);

  @override
  String toString() => 'SyncException: $message';
}
