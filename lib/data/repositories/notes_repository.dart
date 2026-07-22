import 'dart:convert';
import 'dart:typed_data';
import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';

import '../../core/crypto/crypto_manager.dart';
import '../../core/crypto/key_storage.dart';
import '../models/note.dart';
import 'sync_tombstone_store.dart';

/// Repository for managing encrypted notes (separate from vault entries)
class NotesRepository {
  // All repository instances in the foreground isolate share the same Hive
  // box. Serializing mutations prevents an older encryption/write operation
  // from finishing after a newer one and replacing it.
  static Future<void> _writeQueue = Future<void>.value();

  final CryptoManager _cryptoManager;
  final KeyStorage _keyStorage;
  final Uuid _uuid = const Uuid();

  late Box<String> _notesBox;
  bool _isInitialized = false;
  Future<void>? _initializeFuture;

  NotesRepository({
    required CryptoManager cryptoManager,
    required KeyStorage keyStorage,
  })  : _cryptoManager = cryptoManager,
        _keyStorage = keyStorage;

  /// Initialize the notes storage
  Future<void> initialize() async {
    if (_isInitialized) return;

    _initializeFuture ??= _openNotesBox();
    try {
      await _initializeFuture;
    } catch (_) {
      _initializeFuture = null;
      rethrow;
    }
  }

  Future<void> _openNotesBox() async {
    _notesBox = await Hive.openBox<String>('notes');
    _isInitialized = true;
  }

  /// Create a new note
  Future<Note> createNote({
    required String title,
    required String content,
    NoteColor color = NoteColor.white,
    bool isPinned = false,
    List<String> tags = const [],
    bool isChecklist = false,
    List<ChecklistItem> checklistItems = const [],
  }) async {
    final now = DateTime.now();
    final nextSortOrder = await _getNextSortOrder();
    final note = Note(
      uuid: _uuid.v4(),
      title: title,
      content: content,
      color: color,
      isPinned: isPinned,
      tags: tags,
      isChecklist: isChecklist,
      checklistItems: checklistItems,
      sortOrder: nextSortOrder,
      createdAt: now,
      modifiedAt: now,
    );

    await _saveNote(note);
    return note;
  }

  /// Update an existing note
  Future<Note> updateNote(Note note) async {
    final updated = note.copyWith(modifiedAt: DateTime.now());
    await _saveNote(updated);
    return updated;
  }

  /// Delete a note
  Future<void> deleteNote(String uuid, {DateTime? deletedAt}) async {
    if (!_isInitialized) {
      throw StateError('NotesRepository not initialized');
    }
    final deletionTime = deletedAt ?? DateTime.now();
    await _enqueueWrite(() async {
      await _notesBox.delete(uuid);
      await SyncTombstoneStore.recordDeletion(uuid, deletedAt: deletionTime);
    });
  }

  /// Save a note (for sync engine)
  Future<void> saveNote(Note note) async {
    await _saveNote(note);
  }

  /// Save a remotely synced note only if it is still newer when the write
  /// reaches the front of the local mutation queue.
  ///
  /// The sync engine may have read the note just before the editor autosaved.
  /// Re-checking here prevents that stale sync decision from overwriting the
  /// editor's newer work.
  Future<bool> saveNoteIfNewer(Note note) {
    return _enqueueWrite(() async {
      final local = await getNote(note.uuid);
      if (local != null && !note.modifiedAt.isAfter(local.modifiedAt)) {
        return false;
      }

      await _writeNote(note);
      return true;
    });
  }

  /// Get a single note by UUID
  Future<Note?> getNote(String uuid) async {
    if (!_isInitialized) {
      throw StateError('NotesRepository not initialized');
    }

    final base64Encoded = _notesBox.get(uuid);
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

    return Note.fromJson(json);
  }

  /// Get all notes
  Future<List<Note>> getAllNotes() async {
    final notes = await getAllStoredNotes();

    // Filter out archived notes
    final activeNotes = notes.where((n) => !n.isArchived).toList();

    // Sort: pinned first, then by sortOrder asc, then createdAt desc as tiebreaker
    activeNotes.sort((a, b) {
      if (a.isPinned != b.isPinned) {
        return a.isPinned ? -1 : 1;
      }
      final orderCmp = a.sortOrder.compareTo(b.sortOrder);
      if (orderCmp != 0) return orderCmp;
      return b.createdAt.compareTo(a.createdAt);
    });

    return activeNotes;
  }

  /// Get every locally stored note, including archived notes.
  ///
  /// Sync must use this method so archiving a note does not accidentally make
  /// it disappear from the remote index.
  Future<List<Note>> getAllStoredNotes() async {
    if (!_isInitialized) {
      throw StateError('NotesRepository not initialized');
    }

    final notes = <Note>[];
    for (final uuid in _notesBox.keys) {
      try {
        final note = await getNote(uuid as String);
        if (note != null) {
          notes.add(note);
        }
      } catch (e) {
        // Skip corrupted notes
      }
    }

    return notes;
  }

  /// Get all archived notes
  Future<List<Note>> getArchivedNotes() async {
    if (!_isInitialized) {
      throw StateError('NotesRepository not initialized');
    }

    final notes = <Note>[];
    for (final uuid in _notesBox.keys) {
      try {
        final note = await getNote(uuid as String);
        if (note != null && note.isArchived) {
          notes.add(note);
        }
      } catch (e) {
        // Skip corrupted notes
      }
    }

    notes.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    return notes;
  }

  /// Search notes by title or content
  Future<List<Note>> searchNotes(String query) async {
    final allNotes = await getAllNotes();
    if (query.isEmpty) return allNotes;

    final lowerQuery = query.toLowerCase();
    return allNotes.where((note) {
      return note.title.toLowerCase().contains(lowerQuery) ||
          note.content.toLowerCase().contains(lowerQuery) ||
          note.tags.any((tag) => tag.toLowerCase().contains(lowerQuery));
    }).toList();
  }

  /// Get all unique tags
  Future<List<String>> getAllTags() async {
    final allNotes = await getAllNotes();
    final tags = <String>{};
    for (final note in allNotes) {
      tags.addAll(note.tags);
    }
    return tags.toList()..sort();
  }

  /// Reorder notes by updating sortOrder for each UUID in the given order
  Future<void> reorderNotes(List<String> uuidOrder) async {
    for (int i = 0; i < uuidOrder.length; i++) {
      final note = await getNote(uuidOrder[i]);
      if (note != null && note.sortOrder != i) {
        final updated = note.copyWith(
          sortOrder: i,
          modifiedAt: DateTime.now(),
        );
        await _saveNote(updated);
      }
    }
  }

  /// Get the next available sortOrder value
  Future<int> _getNextSortOrder() async {
    int maxOrder = -1;
    for (final uuid in _notesBox.keys) {
      try {
        final note = await getNote(uuid as String);
        if (note != null && note.sortOrder > maxOrder) {
          maxOrder = note.sortOrder;
        }
      } catch (_) {}
    }
    return maxOrder + 1;
  }

  Future<void> _saveNote(Note note) async {
    await _enqueueWrite(() => _writeNote(note));
  }

  Future<void> _writeNote(Note note) async {
    if (!_isInitialized) {
      throw StateError('NotesRepository not initialized');
    }

    final rootKey = await _keyStorage.getRootKey();
    if (rootKey == null) {
      throw StateError('No root key found. User must set up vault first.');
    }

    final jsonString = note.toJsonString();
    final jsonBytes = utf8.encode(jsonString);
    final paddedBytes = _cryptoManager.addRandomPadding(Uint8List.fromList(jsonBytes));
    final encryptedBox = await _cryptoManager.encryptXChaCha20(
      data: paddedBytes,
      key: rootKey,
    );
    final encryptedBytes = encryptedBox.toBytes();
    final base64Encoded = base64Encode(encryptedBytes);

    await _notesBox.put(note.uuid, base64Encoded);
  }

  Future<T> _enqueueWrite<T>(Future<T> Function() operation) {
    final scheduled = _writeQueue.then((_) => operation());
    _writeQueue = scheduled.then<void>(
      (_) {},
      onError: (_, __) {},
    );
    return scheduled;
  }

  /// Get note count
  Future<int> getNoteCount() async {
    if (!_isInitialized) {
      throw StateError('NotesRepository not initialized');
    }
    return _notesBox.length;
  }

  /// Close the notes box
  Future<void> close() async {
    if (_isInitialized) {
      await _writeQueue;
      await _notesBox.close();
      _isInitialized = false;
      _initializeFuture = null;
    }
  }
}
