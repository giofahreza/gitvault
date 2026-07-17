import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gitvault/core/crypto/crypto_manager.dart';
import 'package:gitvault/core/crypto/key_storage.dart';
import 'package:gitvault/core/providers/providers.dart';
import 'package:gitvault/data/models/note.dart';
import 'package:gitvault/data/repositories/notes_repository.dart';
import 'package:gitvault/features/notes/note_editor_screen.dart';

void main() {
  testWidgets(
    'note editor autosaves shortly after an immediate edit',
    (WidgetTester tester) async {
      final repository = _RecordingNotesRepository();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            notesRepositoryProvider.overrideWithValue(repository),
          ],
          child: const MaterialApp(home: NoteEditorDialog()),
        ),
      );

      final fields = find.byType(TextField);
      expect(fields, findsNWidgets(2));
      expect(find.text('Not saved yet'), findsOneWidget);

      await tester.enterText(fields.at(1), 'Saved without waiting');
      await tester.pump();
      expect(find.text('Not saved yet · Save now'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump();

      expect(repository.savedNote?.content, 'Saved without waiting');
      expect(find.text('Saved'), findsOneWidget);
    },
  );

  testWidgets(
    'note editor supports an immediate manual save',
    (WidgetTester tester) async {
      final repository = _RecordingNotesRepository();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            notesRepositoryProvider.overrideWithValue(repository),
          ],
          child: const MaterialApp(home: NoteEditorDialog()),
        ),
      );

      await tester.enterText(
        find.byType(TextField).at(1),
        'Manually saved immediately',
      );
      await tester.pump();
      await tester.tap(find.text('Not saved yet · Save now'));
      await tester.pump();
      await tester.pump();

      expect(repository.savedNote?.content, 'Manually saved immediately');
      expect(find.text('Saved'), findsOneWidget);
    },
  );
}

class _RecordingNotesRepository extends NotesRepository {
  Note? savedNote;

  _RecordingNotesRepository()
      : super(
          cryptoManager: CryptoManager(),
          keyStorage: KeyStorage(),
        );

  @override
  Future<void> initialize() async {}

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
    final now = DateTime.now();
    final note = Note(
      uuid: 'test-note',
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
    savedNote = note;
    return note;
  }

  @override
  Future<Note> updateNote(Note note) async {
    savedNote = note;
    return note;
  }
}
