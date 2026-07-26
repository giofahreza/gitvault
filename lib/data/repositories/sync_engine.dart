import 'dart:convert';
import 'dart:typed_data';
import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';
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
import 'sync_tombstone_store.dart';
import '../../core/services/device_identity_service.dart';

/// Manages synchronization between local vault and GitHub storage
/// Implements "Smart Sync" with conflict resolution via Last Write Wins
/// Syncs both password entries and notes to the same GitHub data folder
class SyncEngine {
  static const String deviceRegistrationMethodSetup = 'setup';
  static const String deviceRegistrationMethodRecovery = 'recovery';
  static const String deviceRegistrationMethodRecoveryApproved =
      'recovery_approved';
  static const String deviceRegistrationMethodRecoveryTokenRotated =
      'recovery_token_rotated';
  static const String deviceRegistrationMethodLink = 'link';
  static const String deviceRegistrationMethodSync = 'sync';
  static const String deviceRegistrationMethodRecognized = 'recognized';
  static const Duration pendingDeviceInviteLifetime = Duration(minutes: 10);
  static const Duration pendingDeviceApprovalLifetime = Duration(seconds: 30);

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

  /// Pulls remote vault content after a device recovery completes.
  ///
  /// Recovery has just proven access to the remote vault, so the first action
  /// must be a deterministic download. Running the full pull-then-push sync here
  /// can join an older in-flight sync and leave the recovered device with an
  /// empty local vault until a later manual sync.
  Future<SyncResult> restoreFromGitHub() async {
    if (!_isInitialized) {
      throw StateError('SyncEngine not initialized');
    }

    final rootKey = await _keyStorage.getRootKey();
    if (rootKey == null) {
      throw StateError('No root key found');
    }

    final pullResult = await _pullFromGitHub(rootKey);
    await _syncDeviceRegistry();
    await _setLastSyncTime(DateTime.now());

    return SyncResult(
      pulled: pullResult.downloaded,
      pushed: 0,
      conflicts: pullResult.conflicts,
    );
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
      final localDeletedAtMap = await SyncTombstoneStore.loadDeletedAtMap(
        box: _syncMetadataBox,
      );

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
          if (await _remoteItemLosesToDeletion(
            uuid: uuid,
            remoteModifiedAt: remoteEntry.modifiedAt,
            remoteIndex: syncIndex,
            localDeletedAtMap: localDeletedAtMap,
          )) {
            conflicts++;
            continue;
          }

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
            if (await _remoteItemLosesToDeletion(
              uuid: uuid,
              remoteModifiedAt: remoteNote.modifiedAt,
              remoteIndex: syncIndex,
              localDeletedAtMap: localDeletedAtMap,
            )) {
              conflicts++;
              continue;
            }

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
                if (await _remoteItemLosesToDeletion(
                  uuid: uuid,
                  remoteModifiedAt: remoteSsh.modifiedAt,
                  remoteIndex: syncIndex,
                  localDeletedAtMap: localDeletedAtMap,
                )) {
                  conflicts++;
                  continue;
                }

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

      final deletionResult = await _applyRemoteDeletions(syncIndex);
      downloaded += deletionResult.downloaded;
      conflicts += deletionResult.conflicts;

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
      final localDeletedAtMap = await SyncTombstoneStore.loadDeletedAtMap(
        box: _syncMetadataBox,
      );
      final localItemUuids = <String>{
        ...entries.map((entry) => entry.uuid),
        ...notes.map((note) => note.uuid),
        ...sshCredentials.map((ssh) => ssh.uuid),
      };

      // If no local data, check if remote index exists
      if (entries.isEmpty &&
          notes.isEmpty &&
          sshCredentials.isEmpty &&
          localDeletedAtMap.isEmpty) {
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
      final Map<String, String> uuidToDeletedAtMap = {
        ...?_lastRemoteIndex?.uuidToDeletedAtMap,
      };
      _mergeDeletedAtMaps(uuidToDeletedAtMap, localDeletedAtMap);
      final remotePathsToDelete = <String>{};
      final tombstoneChangedUuids = <String>{};
      final remoteIndex = _lastRemoteIndex;
      final deletionTimestamp = DateTime.now().toUtc();

      void markDeleted(String uuid, DateTime deletedAt) {
        final remoteFilenameHash = remoteIndex?.uuidToHashMap[uuid];
        if (remoteFilenameHash != null) {
          remotePathsToDelete.add(
            '${Constants.dataFolder}/$remoteFilenameHash${Constants.fileExtension}',
          );
        }

        final removedFromActiveIndex = uuidToHashMap.remove(uuid) != null ||
            uuidToContentHashMap.remove(uuid) != null;
        final existingDeletedAt =
            SyncTombstoneStore.parseDeletedAt(uuidToDeletedAtMap[uuid]);

        if (existingDeletedAt == null || deletedAt.isAfter(existingDeletedAt)) {
          uuidToDeletedAtMap[uuid] = deletedAt.toUtc().toIso8601String();
          tombstoneChangedUuids.add(uuid);
        } else if (removedFromActiveIndex) {
          tombstoneChangedUuids.add(uuid);
        }
      }

      for (final remoteEntry in remoteIndex?.uuidToHashMap.entries ??
          const Iterable<MapEntry<String, String>>.empty()) {
        final uuid = remoteEntry.key;
        if (localItemUuids.contains(uuid) ||
            _remoteItemsNeedingRepair.contains(uuid)) {
          continue;
        }

        final deletedAt = SyncTombstoneStore.parseDeletedAt(
              uuidToDeletedAtMap[uuid],
            ) ??
            deletionTimestamp;
        markDeleted(uuid, deletedAt);
        await SyncTombstoneStore.recordDeletion(
          uuid,
          deletedAt: deletedAt,
          box: _syncMetadataBox,
        );
      }

      Future<bool> localItemLosesToDeletion(
        String uuid,
        DateTime localModifiedAt,
      ) async {
        final deletedAt =
            SyncTombstoneStore.parseDeletedAt(uuidToDeletedAtMap[uuid]);
        if (deletedAt == null) return false;

        if (!localModifiedAt.isAfter(deletedAt)) {
          markDeleted(uuid, deletedAt);
          return true;
        }

        uuidToDeletedAtMap.remove(uuid);
        tombstoneChangedUuids.add(uuid);
        await SyncTombstoneStore.clearDeletion(
          uuid,
          box: _syncMetadataBox,
        );
        return false;
      }

      // Upload each password entry
      for (final entry in entries) {
        if (await localItemLosesToDeletion(entry.uuid, entry.modifiedAt)) {
          continue;
        }

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
        if (await localItemLosesToDeletion(note.uuid, note.modifiedAt)) {
          continue;
        }

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
        if (await localItemLosesToDeletion(ssh.uuid, ssh.modifiedAt)) {
          continue;
        }

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

      final indexChanged = remoteIndex == null ||
          !_mapsEqual(remoteIndex.uuidToHashMap, uuidToHashMap) ||
          !_mapsEqual(
            remoteIndex.uuidToContentHashMap,
            uuidToContentHashMap,
          );
      final tombstoneMapChanged = remoteIndex == null ||
          !_mapsEqual(remoteIndex.uuidToDeletedAtMap, uuidToDeletedAtMap);

      // Do not create a new GitHub commit when the encrypted data set is
      // already current.
      if (!indexChanged && !tombstoneMapChanged) {
        await _deleteRemoteFiles(remotePathsToDelete);
        return PushResult(uploaded: uploaded);
      }

      // Create and upload index
      final newCounter = await _getLocalCounter() + 1;
      final syncIndex = SyncIndex(
        lastUpdated: DateTime.now(),
        monotonicCounter: newCounter,
        uuidToHashMap: uuidToHashMap,
        uuidToContentHashMap: uuidToContentHashMap,
        uuidToDeletedAtMap: uuidToDeletedAtMap,
      );

      final indexBytes = await _encryptIndex(syncIndex, rootKey);
      await _githubService.uploadFile(
        path: Constants.indexFile,
        content: indexBytes,
        commitMessage: 'Update index',
      );

      // Update local counter
      await _setLocalCounter(newCounter);

      await _deleteRemoteFiles(remotePathsToDelete);

      return PushResult(uploaded: uploaded + tombstoneChangedUuids.length);
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

  void _mergeDeletedAtMaps(
    Map<String, String> target,
    Map<String, String> source,
  ) {
    for (final entry in source.entries) {
      final sourceDeletedAt = SyncTombstoneStore.parseDeletedAt(entry.value);
      if (sourceDeletedAt == null) continue;

      final targetDeletedAt =
          SyncTombstoneStore.parseDeletedAt(target[entry.key]);
      if (targetDeletedAt == null || sourceDeletedAt.isAfter(targetDeletedAt)) {
        target[entry.key] = sourceDeletedAt.toIso8601String();
      }
    }
  }

  Future<bool> _remoteItemLosesToDeletion({
    required String uuid,
    required DateTime remoteModifiedAt,
    required SyncIndex remoteIndex,
    required Map<String, String> localDeletedAtMap,
  }) async {
    final remoteDeletedAt =
        SyncTombstoneStore.parseDeletedAt(remoteIndex.uuidToDeletedAtMap[uuid]);
    final localDeletedAt =
        SyncTombstoneStore.parseDeletedAt(localDeletedAtMap[uuid]);

    final winningDeletedAt = _laterDeletedAt(remoteDeletedAt, localDeletedAt);
    if (winningDeletedAt == null) return false;

    if (!remoteModifiedAt.isAfter(winningDeletedAt)) {
      return true;
    }

    if (localDeletedAt != null) {
      localDeletedAtMap.remove(uuid);
      await SyncTombstoneStore.clearDeletion(
        uuid,
        box: _syncMetadataBox,
      );
    }

    return false;
  }

  DateTime? _laterDeletedAt(DateTime? a, DateTime? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a.isAfter(b) ? a : b;
  }

  Future<void> _deleteRemoteFiles(Set<String> remotePaths) async {
    for (final path in remotePaths) {
      try {
        await _githubService.deleteFile(
          path: path,
          commitMessage: 'Delete removed vault item',
        );
      } catch (_) {
        // Non-fatal: the encrypted index is the source of truth.
      }
    }
  }

  Future<PullResult> _applyRemoteDeletions(SyncIndex syncIndex) async {
    int deleted = 0;
    int conflicts = 0;

    for (final entry in syncIndex.uuidToDeletedAtMap.entries) {
      final deletedAt = SyncTombstoneStore.parseDeletedAt(entry.value);
      if (deletedAt == null) continue;

      final localItem = await _getLocalItem(entry.key);
      if (localItem == null) {
        await SyncTombstoneStore.recordDeletion(
          entry.key,
          deletedAt: deletedAt,
          box: _syncMetadataBox,
        );
        continue;
      }

      if (localItem.modifiedAt.isAfter(deletedAt)) {
        await SyncTombstoneStore.clearDeletion(
          entry.key,
          box: _syncMetadataBox,
        );
        conflicts++;
        continue;
      }

      await _deleteLocalItem(localItem, deletedAt);
      deleted++;
    }

    return PullResult(downloaded: deleted, conflicts: conflicts);
  }

  Future<_LocalSyncItem?> _getLocalItem(String uuid) async {
    try {
      final entry = await _vaultRepository.getEntry(uuid);
      if (entry != null) {
        return _LocalSyncItem(
          type: _LocalSyncItemType.vault,
          uuid: uuid,
          modifiedAt: entry.modifiedAt,
        );
      }
    } catch (_) {}

    try {
      final note = await _notesRepository.getNote(uuid);
      if (note != null) {
        return _LocalSyncItem(
          type: _LocalSyncItemType.note,
          uuid: uuid,
          modifiedAt: note.modifiedAt,
        );
      }
    } catch (_) {}

    try {
      final sshRepository = _sshRepository;
      if (sshRepository != null) {
        final credential = await sshRepository.getCredential(uuid);
        if (credential != null) {
          return _LocalSyncItem(
            type: _LocalSyncItemType.ssh,
            uuid: uuid,
            modifiedAt: credential.modifiedAt,
          );
        }
      }
    } catch (_) {}

    return null;
  }

  Future<void> _deleteLocalItem(
    _LocalSyncItem item,
    DateTime deletedAt,
  ) async {
    switch (item.type) {
      case _LocalSyncItemType.vault:
        await _vaultRepository.deleteEntry(item.uuid, deletedAt: deletedAt);
        break;
      case _LocalSyncItemType.note:
        await _notesRepository.deleteNote(item.uuid, deletedAt: deletedAt);
        break;
      case _LocalSyncItemType.ssh:
        await _sshRepository?.deleteCredential(
          item.uuid,
          deletedAt: deletedAt,
        );
        break;
    }
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
  static Future<String> createPendingDeviceInvite({
    required KeyStorage keyStorage,
    required CryptoManager cryptoManager,
    required GitHubService githubService,
  }) async {
    await keyStorage.initialize();

    final rootKey = await keyStorage.getRootKey();
    if (rootKey == null) {
      throw StateError('No root key found');
    }

    final identity =
        await DeviceIdentityService(keyStorage: keyStorage).ensureIdentity();
    final now = DateTime.now();
    final nowIso = now.toIso8601String();
    final inviteId = const Uuid().v4();

    final registry = await _downloadDeviceRegistry(
      keyStorage: keyStorage,
      cryptoManager: cryptoManager,
      githubService: githubService,
      rootKey: rootKey,
    );
    if (registry == null) {
      throw StateError('Could not read device registry');
    }
    final invites = _pendingDeviceInvites(registry, now);
    invites.add({
      'inviteId': inviteId,
      'createdAt': nowIso,
      'expiresAt': now.add(pendingDeviceInviteLifetime).toIso8601String(),
      'createdByDeviceId': identity.id,
      'createdByName': identity.name,
    });
    registry['pendingDeviceInvites'] = invites;

    await _uploadDeviceRegistry(
      keyStorage: keyStorage,
      cryptoManager: cryptoManager,
      githubService: githubService,
      rootKey: rootKey,
      registry: registry,
      commitMessage: 'Create device link invite',
    );

    return inviteId;
  }

  static Future<void> recognizeDeviceRegistration({
    required KeyStorage keyStorage,
    required CryptoManager cryptoManager,
    required GitHubService githubService,
    required String deviceId,
  }) async {
    await keyStorage.initialize();

    final rootKey = await keyStorage.getRootKey();
    if (rootKey == null) {
      throw StateError('No root key found');
    }

    final identity =
        await DeviceIdentityService(keyStorage: keyStorage).ensureIdentity();
    final registry = await _downloadDeviceRegistry(
      keyStorage: keyStorage,
      cryptoManager: cryptoManager,
      githubService: githubService,
      rootKey: rootKey,
    );
    if (registry == null) {
      throw StateError('Could not read device registry');
    }
    final devices = (registry['devices'] as List<dynamic>? ?? [])
        .map((device) => Map<String, dynamic>.from(device as Map))
        .toList();
    final index =
        devices.indexWhere((device) => device['deviceId'] == deviceId);
    if (index < 0) return;

    final nowIso = DateTime.now().toIso8601String();
    devices[index] = {
      ...devices[index],
      'registrationMethod': deviceRegistrationMethodRecognized,
      'recognizedAt': nowIso,
      'recognizedByDeviceId': identity.id,
      'recognizedByName': identity.name,
    };
    registry['devices'] = devices;

    await _uploadDeviceRegistry(
      keyStorage: keyStorage,
      cryptoManager: cryptoManager,
      githubService: githubService,
      rootKey: rootKey,
      registry: registry,
      commitMessage: 'Recognize connected device',
    );
  }

  static Future<String> createPendingRecoveryApproval({
    required KeyStorage keyStorage,
    required CryptoManager cryptoManager,
    required GitHubService githubService,
    required Uint8List rootKey,
  }) async {
    await keyStorage.initialize();

    final identity =
        await DeviceIdentityService(keyStorage: keyStorage).ensureIdentity();
    final now = DateTime.now();
    final approvalId = const Uuid().v4();
    final registry = await _downloadDeviceRegistry(
      keyStorage: keyStorage,
      cryptoManager: cryptoManager,
      githubService: githubService,
      rootKey: rootKey,
    );
    if (registry == null) {
      throw StateError('Could not read device registry');
    }

    final approvals = _deviceApprovalRequests(registry, now: now);
    approvals.add({
      'approvalId': approvalId,
      'deviceId': identity.id,
      'deviceName': identity.name,
      'requestType': 'recovery',
      'status': 'pending',
      'requestedAt': now.toIso8601String(),
      'expiresAt': now.add(pendingDeviceApprovalLifetime).toIso8601String(),
    });
    registry['pendingDeviceApprovals'] = approvals;

    await _uploadDeviceRegistry(
      keyStorage: keyStorage,
      cryptoManager: cryptoManager,
      githubService: githubService,
      rootKey: rootKey,
      registry: registry,
      commitMessage: 'Request device recovery approval',
    );

    return approvalId;
  }

  static Future<DeviceApprovalStatus> getDeviceApprovalStatus({
    required KeyStorage keyStorage,
    required CryptoManager cryptoManager,
    required GitHubService githubService,
    required Uint8List rootKey,
    required String approvalId,
  }) async {
    await keyStorage.initialize();

    final registry = await _downloadDeviceRegistry(
      keyStorage: keyStorage,
      cryptoManager: cryptoManager,
      githubService: githubService,
      rootKey: rootKey,
    );
    if (registry == null) {
      throw StateError('Could not read device registry');
    }

    final approvals = _deviceApprovalRequests(
      registry,
      includeExpiredPending: true,
    );
    for (final approval in approvals) {
      if (approval['approvalId'] != approvalId) continue;

      final status = approval['status'] as String? ?? 'pending';
      if (status == 'approved') {
        if (!_approvalWasAnsweredBeforeExpiry(approval)) {
          return DeviceApprovalStatus.expired(approval);
        }
        return DeviceApprovalStatus.approved(approval);
      }
      if (status == 'denied') {
        if (!_approvalWasAnsweredBeforeExpiry(approval)) {
          return DeviceApprovalStatus.expired(approval);
        }
        return DeviceApprovalStatus.denied(approval);
      }
      if (_approvalIsExpired(approval, DateTime.now())) {
        return DeviceApprovalStatus.expired(approval);
      }
      return DeviceApprovalStatus.pending(approval);
    }

    return DeviceApprovalStatus.expired(null);
  }

  static Future<void> respondToDeviceApproval({
    required KeyStorage keyStorage,
    required CryptoManager cryptoManager,
    required GitHubService githubService,
    required String approvalId,
    required bool approved,
  }) async {
    await keyStorage.initialize();

    final rootKey = await keyStorage.getRootKey();
    if (rootKey == null) {
      throw StateError('No root key found');
    }

    final identity =
        await DeviceIdentityService(keyStorage: keyStorage).ensureIdentity();
    final registry = await _downloadDeviceRegistry(
      keyStorage: keyStorage,
      cryptoManager: cryptoManager,
      githubService: githubService,
      rootKey: rootKey,
    );
    if (registry == null) {
      throw StateError('Could not read device registry');
    }

    final approvals = _deviceApprovalRequests(
      registry,
      includeExpiredPending: true,
    );
    final index = approvals
        .indexWhere((approval) => approval['approvalId'] == approvalId);
    if (index < 0) {
      throw StateError('Recovery request was not found');
    }

    final approval = approvals[index];
    final currentStatus = approval['status'] as String? ?? 'pending';
    if (currentStatus != 'pending') {
      throw StateError('Recovery request was already answered');
    }

    final now = DateTime.now();
    final nowIso = now.toIso8601String();
    if (_approvalIsExpired(approval, now)) {
      approvals[index] = {
        ...approval,
        'status': 'expired',
        'expiredAt': nowIso,
      };
      registry['pendingDeviceApprovals'] = approvals;
      await _uploadDeviceRegistry(
        keyStorage: keyStorage,
        cryptoManager: cryptoManager,
        githubService: githubService,
        rootKey: rootKey,
        registry: registry,
        commitMessage: 'Expire device recovery request',
      );
      throw StateError(
          'Recovery request expired. Ask the new device to try again.');
    }

    approvals[index] = {
      ...approval,
      'status': approved ? 'approved' : 'denied',
      'respondedAt': nowIso,
      'respondedByDeviceId': identity.id,
      'respondedByName': identity.name,
    };
    registry['pendingDeviceApprovals'] = approvals;

    await _uploadDeviceRegistry(
      keyStorage: keyStorage,
      cryptoManager: cryptoManager,
      githubService: githubService,
      rootKey: rootKey,
      registry: registry,
      commitMessage: approved
          ? 'Approve device recovery request'
          : 'Deny device recovery request',
    );
  }

  static Future<void> completeApprovedRecovery({
    required KeyStorage keyStorage,
    required CryptoManager cryptoManager,
    required GitHubService githubService,
    required Uint8List rootKey,
    required String approvalId,
  }) async {
    await keyStorage.initialize();

    final identity =
        await DeviceIdentityService(keyStorage: keyStorage).ensureIdentity();
    final registry = await _downloadDeviceRegistry(
      keyStorage: keyStorage,
      cryptoManager: cryptoManager,
      githubService: githubService,
      rootKey: rootKey,
    );
    if (registry == null) {
      throw StateError('Could not read device registry');
    }

    final approvals = _deviceApprovalRequests(
      registry,
      includeExpiredPending: true,
    );
    Map<String, dynamic>? approval;
    for (final item in approvals) {
      if (item['approvalId'] == approvalId) {
        approval = item;
        break;
      }
    }
    if (approval == null ||
        approval['status'] != 'approved' ||
        !_approvalWasAnsweredBeforeExpiry(approval)) {
      throw StateError('Recovery request was not approved within 30 seconds');
    }

    final nowIso = DateTime.now().toIso8601String();
    final devices = (registry['devices'] as List<dynamic>? ?? [])
        .map((device) => Map<String, dynamic>.from(device as Map))
        .toList();
    final device = {
      'deviceId': identity.id,
      'name': identity.name,
      'lastSeen': nowIso,
      'addedAt': nowIso,
      'registrationMethod': deviceRegistrationMethodRecoveryApproved,
      'recoveryApprovalId': approvalId,
      'approvedByDeviceId': approval['respondedByDeviceId'],
      'approvedByName': approval['respondedByName'],
      'approvedAt': approval['respondedAt'],
    };
    final index = devices.indexWhere((item) => item['deviceId'] == identity.id);
    if (index >= 0) {
      devices[index] = {...devices[index], ...device};
    } else {
      devices.add(device);
    }
    registry['devices'] = devices;

    final approvalIndex =
        approvals.indexWhere((item) => item['approvalId'] == approvalId);
    if (approvalIndex >= 0) {
      approvals[approvalIndex] = {
        ...approvals[approvalIndex],
        'completedAt': nowIso,
      };
      registry['pendingDeviceApprovals'] = approvals;
    }

    await _uploadDeviceRegistry(
      keyStorage: keyStorage,
      cryptoManager: cryptoManager,
      githubService: githubService,
      rootKey: rootKey,
      registry: registry,
      commitMessage: 'Complete approved device recovery',
    );
  }

  static Future<void> completeTokenRotatedRecovery({
    required KeyStorage keyStorage,
    required CryptoManager cryptoManager,
    required GitHubService githubService,
    required Uint8List rootKey,
    required String oldToken,
    required String newToken,
    required String approvalId,
  }) async {
    await keyStorage.initialize();

    if (oldToken.trim() == newToken.trim()) {
      throw StateError('Use a newly generated GitHub token.');
    }

    final identity =
        await DeviceIdentityService(keyStorage: keyStorage).ensureIdentity();
    final registry = await _downloadDeviceRegistry(
      keyStorage: keyStorage,
      cryptoManager: cryptoManager,
      githubService: githubService,
      rootKey: rootKey,
    );
    if (registry == null) {
      throw StateError('Could not read device registry');
    }

    final oldFingerprint = await _githubTokenFingerprint(
      cryptoManager: cryptoManager,
      rootKey: rootKey,
      token: oldToken,
    );
    final newFingerprint = await _githubTokenFingerprint(
      cryptoManager: cryptoManager,
      rootKey: rootKey,
      token: newToken,
    );
    if (oldFingerprint == newFingerprint ||
        registry['activeGitHubTokenFingerprint'] == newFingerprint) {
      throw StateError('Use a newly generated GitHub token.');
    }

    final nowIso = DateTime.now().toIso8601String();
    final devices = (registry['devices'] as List<dynamic>? ?? [])
        .map((device) => Map<String, dynamic>.from(device as Map))
        .toList();
    final device = {
      'deviceId': identity.id,
      'name': identity.name,
      'lastSeen': nowIso,
      'addedAt': nowIso,
      'registrationMethod': deviceRegistrationMethodRecoveryTokenRotated,
      'recoveryApprovalId': approvalId,
      'tokenRotatedAt': nowIso,
    };
    final index = devices.indexWhere((item) => item['deviceId'] == identity.id);
    if (index >= 0) {
      devices[index] = {...devices[index], ...device};
    } else {
      devices.add(device);
    }
    registry['devices'] = devices;
    registry['previousGitHubTokenFingerprint'] =
        registry['activeGitHubTokenFingerprint'] ?? oldFingerprint;
    registry['activeGitHubTokenFingerprint'] = newFingerprint;
    registry['tokenRotatedAt'] = nowIso;
    registry['tokenRotatedByDeviceId'] = identity.id;
    registry['tokenRotatedByName'] = identity.name;

    final approvals = _deviceApprovalRequests(
      registry,
      includeExpiredPending: true,
    );
    final approvalIndex =
        approvals.indexWhere((item) => item['approvalId'] == approvalId);
    if (approvalIndex >= 0) {
      approvals[approvalIndex] = {
        ...approvals[approvalIndex],
        'status': 'recovered_with_new_token',
        'completedAt': nowIso,
      };
      registry['pendingDeviceApprovals'] = approvals;
    }

    await _uploadDeviceRegistry(
      keyStorage: keyStorage,
      cryptoManager: cryptoManager,
      githubService: githubService,
      rootKey: rootKey,
      registry: registry,
      commitMessage: 'Complete token-rotated device recovery',
    );
  }

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
    final registrationMethod = await keyStorage.getDeviceRegistrationMethod();
    final pendingInviteId = await keyStorage.getPendingDeviceInviteId();
    final now = DateTime.now();
    final nowIso = now.toIso8601String();

    final registry = await _downloadDeviceRegistry(
      keyStorage: keyStorage,
      cryptoManager: cryptoManager,
      githubService: githubService,
      rootKey: rootKey,
    );
    if (registry == null) return null;

    final devices = (registry['devices'] as List<dynamic>?) ?? [];
    final pendingInvites = _pendingDeviceInvites(registry, now);
    final rawPendingInvites =
        registry['pendingDeviceInvites'] as List<dynamic>?;
    if (rawPendingInvites != null &&
        rawPendingInvites.length != pendingInvites.length) {
      registry['pendingDeviceInvites'] = pendingInvites;
    }
    Map<String, dynamic>? pendingInvite;
    if (pendingInviteId != null) {
      for (final invite in pendingInvites) {
        if (invite['inviteId'] == pendingInviteId) {
          pendingInvite = invite;
          break;
        }
      }
    }
    final registrationIsInviteVerified =
        registrationMethod == deviceRegistrationMethodLink &&
            pendingInvite != null;
    final verifiedInvite = registrationIsInviteVerified ? pendingInvite : null;
    final linkInviteRejected =
        registrationMethod == deviceRegistrationMethodLink &&
            pendingInviteId != null &&
            pendingInvite == null;
    final resolvedRegistrationMethod =
        registrationMethod == deviceRegistrationMethodLink &&
                verifiedInvite == null
            ? deviceRegistrationMethodSync
            : registrationMethod;
    bool found = false;
    bool needsUpload = rawPendingInvites != null &&
        rawPendingInvites.length != pendingInvites.length;

    final updatedDevices = devices.map((d) {
      final device = Map<String, dynamic>.from(d as Map);
      final isUnverifiedRemoteDevice =
          device['deviceId'] != identity.id && _isUnverifiedDevice(device);
      if (isUnverifiedRemoteDevice &&
          (device['firstSeenByDeviceId'] as String?)?.isEmpty != false) {
        needsUpload = true;
        return {
          ...device,
          'firstSeenByDeviceId': identity.id,
          'firstSeenByName': identity.name,
          'firstSeenAt': nowIso,
        };
      }

      if (device['deviceId'] == identity.id) {
        found = true;
        final previousLastSeen =
            DateTime.tryParse(device['lastSeen'] as String? ?? '');
        final lastSeenIsStale = previousLastSeen == null ||
            now.difference(previousLastSeen) >= const Duration(hours: 6);
        final nameChanged = device['name'] != identity.name;
        final methodChanged = resolvedRegistrationMethod != null &&
            device['registrationMethod'] != resolvedRegistrationMethod;

        if (!lastSeenIsStale && !nameChanged && !methodChanged) {
          return device;
        }

        needsUpload = true;
        final updated = {
          ...device,
          'name': identity.name,
          'lastSeen': nowIso,
        };
        if (resolvedRegistrationMethod != null) {
          updated['registrationMethod'] = resolvedRegistrationMethod;
        }
        if (verifiedInvite != null) {
          updated['linkedInviteId'] = pendingInviteId;
          updated['linkedByDeviceId'] = verifiedInvite['createdByDeviceId'];
          updated['linkedByName'] = verifiedInvite['createdByName'];
          updated['linkedAt'] = nowIso;
        }
        return updated;
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
        'registrationMethod':
            resolvedRegistrationMethod ?? deviceRegistrationMethodSync,
        if (verifiedInvite != null) ...{
          'linkedInviteId': pendingInviteId,
          'linkedByDeviceId': verifiedInvite['createdByDeviceId'],
          'linkedByName': verifiedInvite['createdByName'],
          'linkedAt': nowIso,
        },
      });
    }

    if (verifiedInvite != null) {
      needsUpload = true;
      pendingInvites.removeWhere(
        (invite) => invite['inviteId'] == pendingInviteId,
      );
      registry['pendingDeviceInvites'] = pendingInvites;
      await keyStorage.clearPendingDeviceInviteId();
    } else if (linkInviteRejected) {
      await keyStorage.clearPendingDeviceInviteId();
    }

    registry['devices'] = updatedDevices;
    final registryJson = jsonEncode(registry);

    if (uploadIfNeeded && needsUpload) {
      await _uploadDeviceRegistry(
        keyStorage: keyStorage,
        cryptoManager: cryptoManager,
        githubService: githubService,
        rootKey: rootKey,
        registry: registry,
        commitMessage: 'Update device registry',
      );
    } else {
      await keyStorage.storeDeviceRegistry(registryJson);
    }

    return registry;
  }

  static Future<Map<String, dynamic>?> _downloadDeviceRegistry({
    required KeyStorage keyStorage,
    required CryptoManager cryptoManager,
    required GitHubService githubService,
    required Uint8List rootKey,
  }) async {
    final registryBytes =
        await githubService.downloadFile(Constants.trustedDevicesFile);
    if (registryBytes == null) return <String, dynamic>{};

    try {
      final encryptedBox = EncryptedBox.fromBytes(registryBytes);
      final decryptedPadded = await cryptoManager.decryptXChaCha20(
        box: encryptedBox,
        key: rootKey,
      );
      final decryptedBytes = cryptoManager.removeRandomPadding(decryptedPadded);
      final jsonString = utf8.decode(decryptedBytes);
      return jsonDecode(jsonString) as Map<String, dynamic>;
    } catch (_) {
      // Never replace a registry we could not authenticate or decrypt;
      // doing so could erase the trusted-device list for every client.
      return null;
    }
  }

  static Future<void> _uploadDeviceRegistry({
    required KeyStorage keyStorage,
    required CryptoManager cryptoManager,
    required GitHubService githubService,
    required Uint8List rootKey,
    required Map<String, dynamic> registry,
    required String commitMessage,
  }) async {
    final registryJson = jsonEncode(registry);
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
      commitMessage: commitMessage,
    );
    await keyStorage.storeDeviceRegistry(registryJson);
  }

  static List<Map<String, dynamic>> _pendingDeviceInvites(
    Map<String, dynamic> registry,
    DateTime now,
  ) {
    return (registry['pendingDeviceInvites'] as List<dynamic>? ?? [])
        .map((invite) => Map<String, dynamic>.from(invite as Map))
        .where((invite) {
      final expiresAt = DateTime.tryParse(invite['expiresAt'] as String? ?? '');
      return expiresAt != null && expiresAt.isAfter(now);
    }).toList();
  }

  static bool _isUnverifiedDevice(Map<String, dynamic> device) {
    final method = device['registrationMethod'] as String?;
    if (method == null || method.isEmpty) return false;
    return method != deviceRegistrationMethodSetup &&
        method != deviceRegistrationMethodLink &&
        method != deviceRegistrationMethodRecoveryApproved &&
        method != deviceRegistrationMethodRecoveryTokenRotated &&
        method != deviceRegistrationMethodRecognized;
  }

  static List<Map<String, dynamic>> _deviceApprovalRequests(
    Map<String, dynamic> registry, {
    DateTime? now,
    bool includeExpiredPending = false,
  }) {
    final currentTime = now ?? DateTime.now();
    return (registry['pendingDeviceApprovals'] as List<dynamic>? ?? [])
        .map((approval) => Map<String, dynamic>.from(approval as Map))
        .where((approval) {
      final status = approval['status'] as String? ?? 'pending';
      if (status != 'pending') return true;
      if (includeExpiredPending) return true;

      final expiresAt = DateTime.tryParse(
        approval['expiresAt'] as String? ?? '',
      );
      return expiresAt != null && expiresAt.isAfter(currentTime);
    }).toList();
  }

  static bool _approvalIsExpired(
    Map<String, dynamic> approval,
    DateTime now,
  ) {
    final expiresAt = DateTime.tryParse(
      approval['expiresAt'] as String? ?? '',
    );
    return expiresAt == null || !expiresAt.isAfter(now);
  }

  static bool _approvalWasAnsweredBeforeExpiry(
    Map<String, dynamic> approval,
  ) {
    final expiresAt = DateTime.tryParse(
      approval['expiresAt'] as String? ?? '',
    );
    final respondedAt = DateTime.tryParse(
      approval['respondedAt'] as String? ?? '',
    );
    return expiresAt != null &&
        respondedAt != null &&
        !respondedAt.isAfter(expiresAt);
  }

  static Future<String> _githubTokenFingerprint({
    required CryptoManager cryptoManager,
    required Uint8List rootKey,
    required String token,
  }) {
    return cryptoManager.hmacSha256(
      key: rootKey,
      data: 'github-token:$token',
    );
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

enum _LocalSyncItemType { vault, note, ssh }

class _LocalSyncItem {
  final _LocalSyncItemType type;
  final String uuid;
  final DateTime modifiedAt;

  _LocalSyncItem({
    required this.type,
    required this.uuid,
    required this.modifiedAt,
  });
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

class DeviceApprovalStatus {
  final String state;
  final Map<String, dynamic>? approval;

  const DeviceApprovalStatus._(this.state, this.approval);

  factory DeviceApprovalStatus.pending(Map<String, dynamic> approval) {
    return DeviceApprovalStatus._('pending', approval);
  }

  factory DeviceApprovalStatus.approved(Map<String, dynamic> approval) {
    return DeviceApprovalStatus._('approved', approval);
  }

  factory DeviceApprovalStatus.denied(Map<String, dynamic> approval) {
    return DeviceApprovalStatus._('denied', approval);
  }

  factory DeviceApprovalStatus.expired(Map<String, dynamic>? approval) {
    return DeviceApprovalStatus._('expired', approval);
  }

  bool get isPending => state == 'pending';
  bool get isApproved => state == 'approved';
  bool get isDenied => state == 'denied';
  bool get isExpired => state == 'expired';
}

class SyncException implements Exception {
  final String message;
  SyncException(this.message);

  @override
  String toString() => 'SyncException: $message';
}
