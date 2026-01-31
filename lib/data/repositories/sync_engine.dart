import 'dart:convert';
import 'dart:typed_data';
import 'package:hive/hive.dart';
import '../../core/crypto/crypto_manager.dart';
import '../../core/crypto/key_storage.dart';
import '../../core/services/github_service.dart';
import '../../utils/constants.dart';
import '../models/vault_entry.dart';
import '../models/note.dart';
import '../models/sync_index.dart';
import 'vault_repository.dart';
import 'notes_repository.dart';

/// Manages synchronization between local vault and GitHub storage
/// Implements "Smart Sync" with conflict resolution via Last Write Wins
/// Syncs both password entries and notes to the same GitHub data folder
class SyncEngine {
  final VaultRepository _vaultRepository;
  final NotesRepository _notesRepository;
  final GitHubService _githubService;
  final CryptoManager _cryptoManager;
  final KeyStorage _keyStorage;

  late Box<String> _syncMetadataBox;
  bool _isInitialized = false;

  SyncEngine({
    required VaultRepository vaultRepository,
    required NotesRepository notesRepository,
    required GitHubService githubService,
    required CryptoManager cryptoManager,
    required KeyStorage keyStorage,
  })  : _vaultRepository = vaultRepository,
        _notesRepository = notesRepository,
        _githubService = githubService,
        _cryptoManager = cryptoManager,
        _keyStorage = keyStorage;

  /// Initialize sync engine
  Future<void> initialize() async {
    if (_isInitialized) return;

    _syncMetadataBox = await Hive.openBox<String>('sync_metadata');
    await _vaultRepository.initialize();
    await _notesRepository.initialize();
    _isInitialized = true;
  }

  /// Performs full sync: pull from GitHub then push local changes
  Future<SyncResult> sync() async {
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
      // Download index file
      final indexBytes = await _githubService.downloadFile(Constants.indexFile);

      if (indexBytes == null) {
        // No index yet, first sync
        return PullResult(downloaded: 0, conflicts: 0);
      }

      // Decrypt index
      final syncIndex = await _decryptIndex(indexBytes, rootKey);

      // Verify monotonic counter (anti-rollback)
      final localCounter = await _getLocalCounter();
      if (syncIndex.monotonicCounter < localCounter) {
        throw SyncException('Rollback attack detected! Remote counter is lower than local.');
      }

      // Download each item from the map (could be password entry or note)
      for (final entry in syncIndex.uuidToHashMap.entries) {
        final uuid = entry.key;
        final filenameHash = entry.value;
        final remotePath = '${Constants.dataFolder}/$filenameHash${Constants.fileExtension}';

        // Download file
        final fileBytes = await _githubService.downloadFile(remotePath);
        if (fileBytes == null) continue;

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
              // New note, save it
              await _notesRepository.saveNote(remoteNote);
              downloaded++;
            } else {
              // Conflict resolution: Last Write Wins
              if (remoteNote.modifiedAt.isAfter(localNote.modifiedAt)) {
                await _notesRepository.saveNote(remoteNote);
                downloaded++;
                conflicts++;
              }
            }
          } catch (e) {
            // Could not decrypt as either type, skip
            continue;
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
      // Get all local entries (passwords) and notes
      final entries = await _vaultRepository.getAllEntries();
      final notes = await _notesRepository.getAllNotes();

      // If no local data, check if remote index exists
      if (entries.isEmpty && notes.isEmpty) {
        final indexBytes = await _githubService.downloadFile(Constants.indexFile);
        if (indexBytes == null) {
          // Both local and remote empty - nothing to push
          return PushResult(uploaded: 0);
        }

        // Remote has data but local is empty - already pulled, nothing to push
        return PushResult(uploaded: 0);
      }

      // Build UUID-to-hash map
      final Map<String, String> uuidToHashMap = {};

      // Upload each password entry
      for (final entry in entries) {
        // Generate deterministic filename hash
        final filenameHash = await _cryptoManager.hmacSha256(
          key: rootKey,
          data: entry.uuid,
        );

        uuidToHashMap[entry.uuid] = filenameHash;

        final remotePath = '${Constants.dataFolder}/$filenameHash${Constants.fileExtension}';

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

        final remotePath = '${Constants.dataFolder}/$filenameHash${Constants.fileExtension}';

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

      // Create and upload index
      final newCounter = await _getLocalCounter() + 1;
      final syncIndex = SyncIndex(
        lastUpdated: DateTime.now(),
        monotonicCounter: newCounter,
        uuidToHashMap: uuidToHashMap,
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

  /// Encrypts a vault entry to bytes
  Future<Uint8List> _encryptEntry(VaultEntry entry, Uint8List key) async {
    final jsonString = entry.toJsonString();
    final jsonBytes = utf8.encode(jsonString);
    final paddedBytes = _cryptoManager.addRandomPadding(Uint8List.fromList(jsonBytes));

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
    final paddedBytes = _cryptoManager.addRandomPadding(Uint8List.fromList(jsonBytes));

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

  /// Encrypts the sync index
  Future<Uint8List> _encryptIndex(SyncIndex index, Uint8List key) async {
    final jsonString = jsonEncode(index.toJson());
    final jsonBytes = utf8.encode(jsonString);
    final paddedBytes = _cryptoManager.addRandomPadding(Uint8List.fromList(jsonBytes));

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
    final counterStr = _syncMetadataBox.get('monotonic_counter');
    return counterStr != null ? int.parse(counterStr) : 0;
  }

  /// Sets local monotonic counter
  Future<void> _setLocalCounter(int counter) async {
    await _syncMetadataBox.put('monotonic_counter', counter.toString());
  }

  /// Gets last sync timestamp
  Future<DateTime?> getLastSyncTime() async {
    final timestamp = _syncMetadataBox.get('last_sync');
    return timestamp != null ? DateTime.parse(timestamp) : null;
  }

  /// Sets last sync timestamp
  Future<void> _setLastSyncTime(DateTime time) async {
    await _syncMetadataBox.put('last_sync', time.toIso8601String());
  }

  /// Close sync engine
  Future<void> close() async {
    if (_isInitialized) {
      await _syncMetadataBox.close();
      _isInitialized = false;
    }
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
