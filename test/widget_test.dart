import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gitvault/core/crypto/crypto_manager.dart';
import 'package:gitvault/core/crypto/key_storage.dart';
import 'package:gitvault/core/providers/providers.dart';
import 'package:gitvault/data/models/note.dart';
import 'package:gitvault/data/repositories/notes_repository.dart';
import 'package:gitvault/features/notes/note_editor_screen.dart';
import 'package:gitvault/features/notes/notes_screen.dart';

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

  testWidgets(
    'template picker opens a seeded Markdown draft and preserves metadata',
    (WidgetTester tester) async {
      final repository = _RecordingNotesRepository();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            notesRepositoryProvider.overrideWithValue(repository),
          ],
          child: const MaterialApp(home: NotesScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Add note'));
      await tester.pumpAndSettle();
      expect(find.text('Create note'), findsOneWidget);
      expect(find.text('Meeting'), findsOneWidget);

      await tester.tap(find.text('Meeting'));
      await tester.pumpAndSettle();

      final fields = tester.widgetList<TextField>(find.byType(TextField));
      expect(fields.first.controller?.text, startsWith('Meeting - '));
      expect(fields.last.controller?.text, contains('## Decisions'));

      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump();
      expect(repository.savedNote?.tags, contains('meeting'));
      expect(repository.savedNote?.content, contains('## Actions'));
      expect(repository.savedNote?.formatVersion, 2);
    },
  );

  testWidgets(
    'Markdown toolbar inserts syntax and preview renders headings',
    (WidgetTester tester) async {
      final repository = _RecordingNotesRepository();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            notesRepositoryProvider.overrideWithValue(repository),
          ],
          child: const MaterialApp(
            home: NoteEditorDialog(initialContent: '# Heading\n\nBody'),
          ),
        ),
      );

      await tester.tap(find.text('Preview'));
      await tester.pumpAndSettle();
      expect(find.text('Heading'), findsOneWidget);
      expect(find.text('Body'), findsOneWidget);

      await tester.tap(find.text('Edit'));
      await tester.pump();
      await tester.enterText(find.byType(TextField).last, '');
      await tester.tap(find.byTooltip('Bold'));
      await tester.pump();

      final content = tester.widget<TextField>(find.byType(TextField).last);
      expect(content.controller?.text, '**bold text**');
    },
  );

  testWidgets(
    'editing a legacy checklist persists canonical Markdown',
    (WidgetTester tester) async {
      final now = DateTime.utc(2026, 8, 1);
      final legacy = Note(
        uuid: 'legacy-note',
        title: 'Legacy tasks',
        content: '',
        isChecklist: true,
        checklistItems: const [
          ChecklistItem(text: 'Open task'),
          ChecklistItem(text: 'Completed task', isChecked: true),
        ],
        createdAt: now,
        modifiedAt: now,
      );
      final repository = _RecordingNotesRepository([legacy]);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            notesRepositoryProvider.overrideWithValue(repository),
          ],
          child: MaterialApp(home: NoteEditorDialog(note: legacy)),
        ),
      );

      final contentField = find.byType(TextField).last;
      expect(
        tester.widget<TextField>(contentField).controller?.text,
        '- [ ] Open task\n- [x] Completed task',
      );
      await tester.enterText(
        contentField,
        '- [x] Open task\n- [x] Completed task',
      );
      await tester.pump();
      await tester.tap(find.text('Unsaved changes · Save now'));
      await tester.pumpAndSettle();

      expect(repository.savedNote?.formatVersion, 2);
      expect(repository.savedNote?.isChecklist, isFalse);
      expect(repository.savedNote?.checklistItems, isEmpty);
      expect(repository.savedNote?.content, startsWith('- [x] Open task'));
    },
  );

  testWidgets(
    'opening a heading link positions the editor at that heading',
    (WidgetTester tester) async {
      const content = '# First\nOne\n\n# Second\nTwo\n';
      final now = DateTime.utc(2026, 8, 1);
      final note = Note(
        uuid: 'linked-note',
        title: 'Linked note',
        content: content,
        formatVersion: 2,
        createdAt: now,
        modifiedAt: now,
      );
      final repository = _RecordingNotesRepository([note]);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            notesRepositoryProvider.overrideWithValue(repository),
          ],
          child: MaterialApp(
            home: NoteEditorDialog(note: note, initialHeading: 'Second'),
          ),
        ),
      );
      await tester.pump();

      final field = tester.widget<TextField>(find.byType(TextField).last);
      expect(
          field.controller?.selection.baseOffset, content.indexOf('# Second'),);
    },
  );
}

class _RecordingNotesRepository extends NotesRepository {
  Note? savedNote;
  final Map<String, Note> notes;

  _RecordingNotesRepository([Iterable<Note> initialNotes = const []])
      : notes = {for (final note in initialNotes) note.uuid: note},
        super(
          cryptoManager: CryptoManager(),
          keyStorage: KeyStorage(),
        );

  @override
  Future<void> initialize() async {}

  @override
  Future<List<Note>> getAllNotes() async => notes.values
      .where((note) => !note.isArchived && !note.isTemplate)
      .toList();

  @override
  Future<List<Note>> getAllStoredNotes() async => notes.values.toList();

  @override
  Future<List<Note>> getTemplates() async =>
      notes.values.where((note) => note.isTemplate).toList();

  @override
  Future<Note> createNote({
    required String title,
    required String content,
    int formatVersion = 2,
    NoteColor color = NoteColor.white,
    bool isPinned = false,
    List<String> tags = const [],
    List<String> aliases = const [],
    bool isChecklist = false,
    List<ChecklistItem> checklistItems = const [],
    DateTime? journalDate,
    bool isTemplate = false,
  }) async {
    final now = DateTime.now();
    final note = Note(
      uuid: 'test-note',
      title: title,
      content: content,
      formatVersion: formatVersion,
      color: color,
      isPinned: isPinned,
      tags: tags,
      aliases: aliases,
      isChecklist: isChecklist,
      checklistItems: checklistItems,
      journalDate: journalDate,
      isTemplate: isTemplate,
      createdAt: now,
      modifiedAt: now,
    );
    savedNote = note;
    notes[note.uuid] = note;
    return note;
  }

  @override
  Future<Note> updateNote(Note note) async {
    savedNote = note;
    notes[note.uuid] = note;
    return note;
  }
}
