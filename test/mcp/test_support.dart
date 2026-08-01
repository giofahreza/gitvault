import 'dart:io';

import 'package:gitvault/core/crypto/crypto_manager.dart';
import 'package:gitvault/core/crypto/key_storage.dart';
import 'package:gitvault/data/models/note.dart';
import 'package:gitvault/data/repositories/notes_repository.dart';
import 'package:gitvault/mcp/mcp_client_registry.dart';
import 'package:hive/hive.dart';

class MemoryNotesRepository extends NotesRepository {
  final Map<String, Note> notes;

  MemoryNotesRepository(Iterable<Note> notes)
      : notes = {for (final note in notes) note.uuid: note},
        super(
          cryptoManager: CryptoManager(),
          keyStorage: KeyStorage(),
        );

  @override
  Future<void> initialize() async {}

  @override
  Future<Note?> getNote(String uuid) async => notes[uuid];

  @override
  Future<List<Note>> getAllNotes() async {
    return notes.values.where((note) => !note.isArchived).toList();
  }

  @override
  Future<List<Note>> getAllStoredNotes() async => notes.values.toList();

  @override
  Future<Note> createNote({
    required String title,
    required String content,
    NoteColor color = NoteColor.white,
    bool isPinned = false,
    List<String> tags = const [],
    bool isChecklist = false,
    List<ChecklistItem> checklistItems = const [],
  }) async {
    final now = DateTime.now().toUtc();
    final note = Note(
      uuid: 'created-${notes.length + 1}',
      title: title,
      content: content,
      color: color,
      isPinned: isPinned,
      tags: tags,
      isChecklist: isChecklist,
      checklistItems: checklistItems,
      createdAt: now,
      modifiedAt: now,
    );
    notes[note.uuid] = note;
    return note;
  }

  @override
  Future<Note?> updateNoteIfUnchanged(
    Note note, {
    required DateTime expectedModifiedAt,
  }) async {
    final current = notes[note.uuid];
    if (current == null ||
        !current.modifiedAt.isAtSameMomentAs(expectedModifiedAt)) {
      return null;
    }
    final updated = note.copyWith(
      modifiedAt: DateTime.now().toUtc().add(const Duration(milliseconds: 1)),
    );
    notes[note.uuid] = updated;
    return updated;
  }

  @override
  Future<bool> deleteNoteIfUnchanged(
    String uuid, {
    required DateTime expectedModifiedAt,
    DateTime? deletedAt,
  }) async {
    final current = notes[uuid];
    if (current == null ||
        !current.modifiedAt.isAtSameMomentAs(expectedModifiedAt)) {
      return false;
    }
    notes.remove(uuid);
    return true;
  }

  void replace(Note note) {
    notes[note.uuid] = note;
  }
}

Note testNote({
  required String id,
  required String title,
  String content = 'Body',
  List<String> tags = const [],
  bool archived = false,
  DateTime? modifiedAt,
}) {
  final timestamp =
      modifiedAt ?? DateTime.utc(2026, 7, 29, 12, 0, id.hashCode % 59);
  return Note(
    uuid: id,
    title: title,
    content: content,
    tags: tags,
    isArchived: archived,
    createdAt: timestamp.subtract(const Duration(days: 1)),
    modifiedAt: timestamp,
  );
}

Future<Directory> initializeTestHive() async {
  final directory = await Directory.systemTemp.createTemp('gitvault-mcp-test-');
  Hive.init(directory.path);
  return directory;
}

Future<void> resetMcpBoxes() async {
  for (final name in [
    McpClientRegistry.settingsBoxName,
    McpClientRegistry.activityBoxName,
  ]) {
    if (Hive.isBoxOpen(name)) {
      await Hive.box<String>(name).close();
    }
    await Hive.deleteBoxFromDisk(name);
  }
}

Future<void> closeTestHive(Directory directory) async {
  await Hive.close();
  if (await directory.exists()) {
    await directory.delete(recursive: true);
  }
}
