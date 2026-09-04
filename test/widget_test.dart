import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:gitvault/core/auth/pin_auth.dart';
import 'package:gitvault/core/crypto/crypto_manager.dart';
import 'package:gitvault/core/crypto/key_storage.dart';
import 'package:gitvault/core/notes/knowledge_index.dart';
import 'package:gitvault/core/providers/providers.dart';
import 'package:gitvault/data/models/note.dart';
import 'package:gitvault/data/models/vault_entry.dart';
import 'package:gitvault/data/repositories/notes_repository.dart';
import 'package:gitvault/features/notes/knowledge_graph_screen.dart';
import 'package:gitvault/features/notes/note_editor_screen.dart';
import 'package:gitvault/features/notes/notes_screen.dart';
import 'package:gitvault/features/onboarding/onboarding_screen.dart';
import 'package:gitvault/features/settings/settings_screen.dart';
import 'package:gitvault/features/ssh/ssh_screen.dart';
import 'package:gitvault/features/totp/totp_codes_page.dart';
import 'package:gitvault/features/vault/vault_screen.dart';
import 'package:gitvault/main.dart' show MainScreen;
import 'package:gitvault/utils/auto_bullet.dart';
import 'package:gitvault/utils/recovery_phrase_grid.dart';

void main() {
  late Directory hiveDirectory;

  setUpAll(() async {
    hiveDirectory = Directory.systemTemp.createTempSync('gitvault-widget-');
    Hive.init(hiveDirectory.path);
  });

  tearDownAll(() async {
    await Hive.close();
    hiveDirectory.deleteSync(recursive: true);
  });

  test('GitHub credential revision survives provider container disposal', () {
    final sourceRevision = KeyStorage.githubCredentialsRevision;
    final originalRevision = sourceRevision.value;
    final firstContainer = ProviderContainer();

    try {
      final firstRevision =
          firstContainer.read(githubCredentialsRevisionProvider);
      expect(firstRevision.value, originalRevision);

      sourceRevision.value = originalRevision + 1;
      expect(firstRevision.value, originalRevision + 1);

      firstContainer.dispose();
      sourceRevision.value = originalRevision + 2;

      final secondContainer = ProviderContainer();
      try {
        final secondRevision =
            secondContainer.read(githubCredentialsRevisionProvider);
        expect(secondRevision.value, originalRevision + 2);

        sourceRevision.value = originalRevision + 3;
        expect(secondRevision.value, originalRevision + 3);
      } finally {
        secondContainer.dispose();
      }
    } finally {
      sourceRevision.value = originalRevision;
    }
  });

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
      final backlinks = tester.widget<IconButton>(
        find.byWidgetPredicate(
          (widget) => widget is IconButton && widget.tooltip == 'Backlinks',
        ),
      );
      expect(backlinks.onPressed, isNotNull);
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

  test('task list auto bullet continues as an unchecked task', () {
    expect(AutoBullet.detectBulletPrefix('- [ ] Open item'), '- [ ] ');
    expect(AutoBullet.getNextBullet('- [x] '), '- [ ] ');
    expect(AutoBullet.getNextBullet('  * [X] '), '  * [ ] ');
    expect(AutoBullet.isEmptyBullet('- [ ] '), isTrue);
  });

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
    'populated note fields keep stable accessibility labels',
    (WidgetTester tester) async {
      final now = DateTime.utc(2026, 8, 11);
      final note = Note(
        uuid: 'accessible-note',
        title: 'Accessible title',
        content: '# Accessible body',
        formatVersion: 2,
        createdAt: now,
        modifiedAt: now,
      );
      final repository = _RecordingNotesRepository([note]);
      final semantics = tester.ensureSemantics();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            notesRepositoryProvider.overrideWithValue(repository),
          ],
          child: MaterialApp(home: NoteEditorDialog(note: note)),
        ),
      );
      await tester.pump();

      expect(_semanticsWidgetWithLabel('Title'), findsOneWidget);
      expect(_semanticsWidgetWithLabel('Write Markdown'), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, 'A title');
      await tester.enterText(find.byType(TextField).last, 'A body');
      await tester.pump();

      expect(find.text('Title'), findsNothing);
      expect(find.text('Write Markdown...'), findsNothing);
      semantics.dispose();
    },
  );

  testWidgets(
    'empty note fields do not duplicate their accessibility labels',
    (WidgetTester tester) async {
      final repository = _RecordingNotesRepository();
      final semantics = tester.ensureSemantics();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            notesRepositoryProvider.overrideWithValue(repository),
          ],
          child: const MaterialApp(home: NoteEditorDialog()),
        ),
      );
      await tester.pump();

      expect(_semanticsWidgetWithLabel('Title'), findsOneWidget);
      expect(_semanticsWidgetWithLabel('Write Markdown'), findsOneWidget);
      semantics.dispose();
    },
  );

  testWidgets(
    'adding a note tag waits for the dialog exit animation',
    (WidgetTester tester) async {
      final now = DateTime.utc(2026, 8, 11);
      final note = Note(
        uuid: 'tagged-note',
        title: 'Incident review',
        content: '# Incident review',
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
          child: MaterialApp(home: NoteEditorDialog(note: note)),
        ),
      );
      await tester.pump();

      await tester.tap(find.byTooltip('Add tag'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Tag name'), 'Ops');
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();

      expect(find.text('Ops'), findsOneWidget);
      expect(tester.takeException(), isNull);
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
      expect(find.byType(SelectableText), findsNothing);

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
        field.controller?.selection.baseOffset,
        content.indexOf('# Second'),
      );
    },
  );

  testWidgets('search exposes and focuses an editable text field',
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

    await tester.tap(find.byTooltip('Search'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.focusNode?.hasFocus, isTrue);
    expect(find.bySemanticsLabel(RegExp('Search notes')), findsOneWidget);
  });

  testWidgets('2FA delete from edit waits for the edit dialog to close',
      (WidgetTester tester) async {
    final now = DateTime.utc(2026, 8, 9);
    final entry = VaultEntry(
      uuid: 'totp-entry',
      title: 'GitHub',
      username: 'alice@example.com',
      password: '',
      totpSecret: 'JBSWY3DPEHPK3PXP',
      createdAt: now,
      modifiedAt: now,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          vaultEntriesProvider.overrideWith((ref) async => [entry]),
        ],
        child: const MaterialApp(home: TotpCodesPage()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Edit 2FA'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete 2FA'));
    await tester.pumpAndSettle();

    expect(find.text('Delete 2FA Code'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('2FA edit validation clears after correcting the secret',
      (WidgetTester tester) async {
    final now = DateTime.utc(2026, 8, 9);
    final entry = VaultEntry(
      uuid: 'totp-validation-entry',
      title: 'GitHub',
      username: 'alice@example.com',
      password: '',
      totpSecret: 'JBSWY3DPEHPK3PXP',
      createdAt: now,
      modifiedAt: now,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          vaultEntriesProvider.overrideWith((ref) async => [entry]),
        ],
        child: const MaterialApp(home: TotpCodesPage()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Edit 2FA'));
    await tester.pumpAndSettle();
    await tester.enterText(_formField('Secret Key'), 'not@base32');
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(find.text('Enter a valid Base32 secret'), findsOneWidget);

    await tester.enterText(_formField('Secret Key'), 'JBSWY3DPEHPK3PXP');
    await tester.pump();
    expect(find.text('Enter a valid Base32 secret'), findsNothing);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('2FA edit requires auth before revealing the secret',
      (WidgetTester tester) async {
    final now = DateTime.utc(2026, 8, 9);
    final entry = VaultEntry(
      uuid: 'totp-secret-entry',
      title: 'GitHub',
      username: 'alice@example.com',
      password: '',
      totpSecret: 'JBSWY3DPEHPK3PXP',
      createdAt: now,
      modifiedAt: now,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          vaultEntriesProvider.overrideWith((ref) async => [entry]),
          biometricEnabledProvider.overrideWith((ref) => false),
          pinEnabledProvider.overrideWith((ref) async => false),
        ],
        child: const MaterialApp(home: TotpCodesPage()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Edit 2FA'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Show secret key'), findsOneWidget);
    expect(find.byTooltip('Hide secret key'), findsNothing);

    await tester.tap(find.byTooltip('Show secret key'));
    await tester.pumpAndSettle();

    expect(find.text('Set Up PIN'), findsWidgets);
    expect(
      find.text(
        'Authenticate to view 2FA secret. Set up a PIN now to continue on this device.',
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('Hide secret key'), findsNothing);

    await tester.tap(find.text('Not Now'));
    await tester.pumpAndSettle();

    expect(find.text('Edit 2FA Code'), findsOneWidget);
    expect(find.byTooltip('Show secret key'), findsOneWidget);
    expect(find.byTooltip('Hide secret key'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('password validation clears as required fields are corrected',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          vaultEntriesProvider.overrideWith((ref) async => []),
        ],
        child: const MaterialApp(home: VaultScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Add password'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pump();

    expect(find.text('Title is required'), findsOneWidget);
    expect(find.text('Username or email is required'), findsOneWidget);
    expect(find.text('Password is required'), findsOneWidget);

    await tester.enterText(_formField('Title'), 'Example');
    await tester.enterText(_formField('Username/Email'), 'user@example.com');
    await tester.enterText(_formField('Password'), 'correct horse');
    await tester.pump();

    expect(find.text('Title is required'), findsNothing);
    expect(find.text('Username or email is required'), findsNothing);
    expect(find.text('Password is required'), findsNothing);
  });

  testWidgets('password search matches visible entry notes',
      (WidgetTester tester) async {
    final now = DateTime.utc(2026, 8, 12);
    final entry = VaultEntry(
      uuid: 'password-notes-search',
      title: 'Primary email',
      username: 'alice@example.com',
      password: 'secret',
      notes: 'Recovery contact is the blue mailbox',
      createdAt: now,
      modifiedAt: now,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          vaultEntriesProvider.overrideWith((ref) async => [entry]),
        ],
        child: const MaterialApp(home: VaultScreen()),
      ),
    );
    await tester.pumpAndSettle();
    final semantics = tester.ensureSemantics();

    await tester.tap(find.byTooltip('Search'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    await tester.enterText(find.byType(TextField), 'blue mailbox');
    await tester.pump();

    expect(find.text('Primary email'), findsOneWidget);
    expect(find.text('No matching entries'), findsNothing);
    expect(
      find.bySemanticsLabel(RegExp(r'^Search passwords')),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('2FA validation clears as required fields are corrected',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          vaultEntriesProvider.overrideWith((ref) async => []),
        ],
        child: const MaterialApp(home: TotpCodesPage()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Add 2FA code'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add 2FA Code'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add'));
    await tester.pump();

    expect(find.text('Service name is required'), findsOneWidget);
    expect(find.text('Secret key is required'), findsOneWidget);

    await tester.enterText(_formField('Service Name'), 'GitHub');
    await tester.enterText(_formField('Secret Key'), 'JBSWY3DPEHPK3PXP');
    await tester.pump();

    expect(find.text('Service name is required'), findsNothing);
    expect(find.text('Secret key is required'), findsNothing);
  });

  testWidgets('SSH validation clears as required fields are corrected',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sshCredentialsProvider.overrideWith((ref) async => []),
        ],
        child: const MaterialApp(home: SshScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Add SSH credential'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add'));
    await tester.pump();

    expect(find.text('Label is required'), findsOneWidget);
    expect(find.text('Host is required'), findsOneWidget);
    expect(find.text('Username is required'), findsOneWidget);
    expect(find.text('Password is required'), findsOneWidget);

    await tester.enterText(_formField('Label'), 'Test server');
    await tester.enterText(_formField('Host'), 'example.com');
    await tester.enterText(_formField('Username'), 'alice');
    await tester.enterText(_formField('Password'), 'secret');
    await tester.pump();

    expect(find.text('Label is required'), findsNothing);
    expect(find.text('Host is required'), findsNothing);
    expect(find.text('Username is required'), findsNothing);
    expect(find.text('Password is required'), findsNothing);
  });

  testWidgets('switching SSH authentication clears password validation state',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sshCredentialsProvider.overrideWith((ref) async => []),
        ],
        child: const MaterialApp(home: SshScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Add SSH credential'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add'));
    await tester.pump();
    expect(find.text('Password is required'), findsOneWidget);

    await tester.tap(find.text('Key'));
    await tester.pump();

    expect(find.text('Passphrase'), findsOneWidget);
    expect(find.text('Password is required'), findsNothing);
  });

  testWidgets('compact SSH key picker stacks status above its action',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sshCredentialsProvider.overrideWith((ref) async => []),
        ],
        child: const MaterialApp(home: SshScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Add SSH credential'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Key'));
    await tester.pump();

    final statusRect = tester.getRect(find.text('No private key loaded'));
    final pickerRect = tester.getRect(find.text('Pick File'));
    expect(pickerRect.top, greaterThan(statusRect.bottom));
    expect(find.text('Password'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact 2FA cards separate identity from row actions',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final semantics = tester.ensureSemantics();
    final now = DateTime.utc(2026, 8, 9);
    final entry = VaultEntry(
      uuid: 'compact-totp',
      title: 'GitHub Prod',
      username: 'alice@example.com',
      password: '',
      totpSecret: 'JBSWY3DPEHPK3PXP',
      tags: const ['Work'],
      createdAt: now,
      modifiedAt: now,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          vaultEntriesProvider.overrideWith((ref) async => [entry]),
        ],
        child: const MaterialApp(home: TotpCodesPage()),
      ),
    );
    await tester.pumpAndSettle();

    final accountRect = tester.getRect(find.text('alice@example.com'));
    final copyRect = tester.getRect(find.text('Copy'));
    expect(copyRect.top, greaterThanOrEqualTo(accountRect.bottom));
    expect(
      find.bySemanticsLabel(RegExp('Copy 2FA code')),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(RegExp('GitHub Prod.*Copy 2FA code')),
      findsNothing,
    );
    expect(tester.widget<Card>(find.byType(Card)).semanticContainer, isFalse);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('compact navigation only labels the selected destination',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          vaultEntriesProvider.overrideWith((ref) async => []),
          notesRepositoryProvider.overrideWithValue(
            _RecordingNotesRepository(),
          ),
          sshCredentialsProvider.overrideWith((ref) async => []),
        ],
        child: const MaterialApp(home: MainScreen()),
      ),
    );
    await tester.pump();

    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).labelBehavior,
      NavigationDestinationLabelBehavior.onlyShowSelected,
    );

    tester.view.physicalSize = const Size(420, 800);
    await tester.pump();

    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).labelBehavior,
      NavigationDestinationLabelBehavior.alwaysShow,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('primary actions expose one semantic target',
      (WidgetTester tester) async {
    final semantics = tester.ensureSemantics();
    final now = DateTime.utc(2026, 8, 9);
    final password = VaultEntry(
      uuid: 'semantic-password',
      title: 'Email Primary',
      username: 'alice@example.com',
      password: 'secret',
      createdAt: now,
      modifiedAt: now,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          vaultEntriesProvider.overrideWith((ref) async => [password]),
        ],
        child: const MaterialApp(home: VaultScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Add password'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp('Email Primary.*alice@example.com')),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          vaultEntriesProvider.overrideWith((ref) async => []),
        ],
        child: const MaterialApp(home: TotpCodesPage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Add 2FA code'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          notesRepositoryProvider.overrideWithValue(
            _RecordingNotesRepository(),
          ),
        ],
        child: const MaterialApp(home: NotesScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Add note'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sshCredentialsProvider.overrideWith((ref) async => []),
        ],
        child: const MaterialApp(home: SshScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Add SSH credential'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('note reorder handles remain accessible after reordering',
      (WidgetTester tester) async {
    final now = DateTime.utc(2026, 8, 9);
    final repository = _RecordingNotesRepository([
      _note('alpha', 'Alpha', now),
      _note('beta', 'Beta', now),
      _note('gamma', 'Gamma', now),
    ]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          notesRepositoryProvider.overrideWithValue(repository),
        ],
        child: const MaterialApp(home: NotesScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final listViewButton = find.byTooltip('List view');
    if (listViewButton.evaluate().isNotEmpty) {
      await tester.tap(listViewButton);
      await tester.pumpAndSettle();
    }

    final handles = find.bySemanticsLabel('Reorder note');
    expect(handles, findsNWidgets(3));

    await tester.drag(handles.first, const Offset(0, 150));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(repository.reorderedUuids, isNotNull);
    expect(find.bySemanticsLabel('Reorder note'), findsNWidgets(3));
  });

  testWidgets('archiving a list note removes the dismissed row immediately',
      (WidgetTester tester) async {
    final now = DateTime.utc(2026, 8, 9);
    final repository = _RecordingNotesRepository([
      _note('alpha', 'Alpha', now),
      _note('beta', 'Beta', now),
    ]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          notesRepositoryProvider.overrideWithValue(repository),
        ],
        child: const MaterialApp(home: NotesScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final listViewButton = find.byTooltip('List view');
    if (listViewButton.evaluate().isNotEmpty) {
      await tester.tap(listViewButton);
      await tester.pumpAndSettle();
    }

    await tester.drag(find.text('Alpha'), const Offset(-420, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));

    expect(find.text('Alpha'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpAndSettle();
    expect(repository.notes['alpha']?.isArchived, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'desktop list swipe right does not pin a note',
    (WidgetTester tester) async {
      final now = DateTime.utc(2026, 8, 9);
      final repository = _RecordingNotesRepository([
        _note('alpha', 'Alpha', now),
        _note('beta', 'Beta', now),
      ]);

      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      try {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              notesRepositoryProvider.overrideWithValue(repository),
            ],
            child: const MaterialApp(home: NotesScreen()),
          ),
        );
        await tester.pumpAndSettle();

        final listViewButton = find.byTooltip('List view');
        if (listViewButton.evaluate().isNotEmpty) {
          await tester.tap(listViewButton);
          await tester.pumpAndSettle();
        }

        await tester.drag(find.text('Alpha'), const Offset(320, 0));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 450));

        expect(repository.notes['alpha']?.isPinned, isFalse);
        expect(repository.notes['alpha']?.isArchived, isFalse);
        expect(tester.takeException(), isNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'desktop list uses drag handle for reorder and does not trigger swipe when tapped',
    (WidgetTester tester) async {
      final now = DateTime.utc(2026, 8, 9);
      final repository = _RecordingNotesRepository([
        _note('alpha', 'Alpha', now),
        _note('beta', 'Beta', now),
        _note('gamma', 'Gamma', now),
      ]);

      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      try {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              notesRepositoryProvider.overrideWithValue(repository),
            ],
            child: const MaterialApp(home: NotesScreen()),
          ),
        );
        await tester.pumpAndSettle();

        final listViewButton = find.byTooltip('List view');
        if (listViewButton.evaluate().isNotEmpty) {
          await tester.tap(listViewButton);
          await tester.pumpAndSettle();
        }

        final handle = find.bySemanticsLabel('Reorder note').first;
        expect(handle, findsOneWidget);

        final rect = tester.getRect(handle);
        await tester.tapAt(rect.center);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        expect(repository.notes['alpha']?.isPinned, isFalse);
        expect(repository.notes['alpha']?.isArchived, isFalse);
        expect(repository.reorderedUuids, isNull);
        expect(tester.takeException(), isNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets('templates never appear in regular notes and are listed separately',
      (WidgetTester tester) async {
    final now = DateTime.utc(2026, 8, 12);
    final repository = _RecordingNotesRepository([
      _note('regular', 'Regular note', now),
      _note('template', 'Saved template', now).copyWith(isTemplate: true),
    ]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          notesRepositoryProvider.overrideWithValue(repository),
        ],
        child: const MaterialApp(home: NotesScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Regular note'), findsOneWidget);
    expect(find.text('Saved template'), findsNothing);

    await tester.tap(find.byTooltip('More note actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Templates'));
    await tester.pumpAndSettle();

    expect(find.text('Saved template'), findsOneWidget);
    expect(find.text('Regular note'), findsNothing);
  });

  testWidgets('recovery phrase grid lays out inside an alert dialog',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final words = List<String>.generate(24, (index) => 'word${index + 1}');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AlertDialog(
            title: const Text('Your Recovery Phrase'),
            content: SingleChildScrollView(
              child: RecoveryPhraseGrid(words: words),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('word24'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact knowledge graph keeps its title and expands search',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _RecordingNotesRepository([
      _note('graph-note', 'Graph note', DateTime.utc(2026, 8, 9)),
    ]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          notesRepositoryProvider.overrideWithValue(repository),
          knowledgeIndexProvider.overrideWith(
            (ref) async => KnowledgeIndex.build(repository.notes.values),
          ),
        ],
        child: const MaterialApp(home: KnowledgeGraphScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Knowledge graph'), findsOneWidget);
    expect(find.byTooltip('Find note'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('Find note'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byTooltip('Close search'), findsOneWidget);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.focusNode?.hasFocus, isTrue);
    expect(tester.testTextInput.hasAnyClients, isTrue);

    await tester.enterText(find.byType(TextField), 'Graph');
    await tester.pump();
    expect(find.bySemanticsLabel(RegExp(r'^Find note')), findsOneWidget);
    expect(find.text('Graph note'), findsOneWidget);
  });

  testWidgets('compact knowledge graph starts with every node in view',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final timestamp = DateTime.utc(2026, 8, 11);
    final repository = _RecordingNotesRepository([
      _note('alpha', 'Alpha', timestamp),
      _note('beta', 'Beta', timestamp),
      _note('gamma', 'Gamma', timestamp),
    ]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          notesRepositoryProvider.overrideWithValue(repository),
          knowledgeIndexProvider.overrideWith(
            (ref) async => KnowledgeIndex.build(repository.notes.values),
          ),
        ],
        child: const MaterialApp(home: KnowledgeGraphScreen()),
      ),
    );
    await tester.pumpAndSettle();

    for (final title in const ['Alpha', 'Beta', 'Gamma']) {
      final button = find.ancestor(
        of: find.text(title),
        matching: find.byWidgetPredicate((widget) => widget is OutlinedButton),
      );
      expect(button, findsOneWidget);
      final rect = tester.getRect(button);
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(390));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('active graph filter stays visible after compact resize',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _RecordingNotesRepository([
      _note('graph-note', 'Graph note', DateTime.utc(2026, 8, 9)),
    ]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          notesRepositoryProvider.overrideWithValue(repository),
          knowledgeIndexProvider.overrideWith(
            (ref) async => KnowledgeIndex.build(repository.notes.values),
          ),
        ],
        child: const MaterialApp(home: KnowledgeGraphScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'missing');
    await tester.pump();
    expect(find.text('No matching notes'), findsOneWidget);

    tester.view.physicalSize = const Size(420, 800);
    await tester.pump();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text, 'missing');
    expect(find.byTooltip('Close search'), findsOneWidget);

    await tester.tap(find.byTooltip('Close search'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Graph note'), findsOneWidget);
  });

  testWidgets('canceling duress setup waits for dialog teardown',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final keyStorage = _FakeKeyStorage();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          keyStorageProvider.overrideWithValue(keyStorage),
          pinEnabledProvider.overrideWith((ref) async => false),
        ],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Duress Mode'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(
      find.widgetWithText(TextField, 'Panic PIN'),
      '123456',
    );
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(tester.testTextInput.editingState?['text'], isEmpty);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Duress Mode'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('PIN setup fields disable browser autofill and learning',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final keyStorage = _FakeKeyStorage();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          keyStorageProvider.overrideWithValue(keyStorage),
          pinEnabledProvider.overrideWith((ref) async => false),
        ],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.text('PIN Lock'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Set Up PIN'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    for (final label in ['Enter PIN (4-6 digits)', 'Confirm PIN']) {
      final field = tester.widget<TextField>(
        find.widgetWithText(TextField, label),
      );
      expect(field.autofillHints, isNull);
      expect(field.autocorrect, isFalse);
      expect(field.enableSuggestions, isFalse);
      expect(field.enableIMEPersonalizedLearning, isFalse);
    }
  });

  testWidgets('settings exposes AI Apps on desktop platforms only',
      (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final keyStorage = _FakeKeyStorage();

    try {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            keyStorageProvider.overrideWithValue(keyStorage),
            pinEnabledProvider.overrideWith((ref) async => false),
          ],
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('AI Apps'), findsWidgets);
      expect(
        find.text('Connect MCP-compatible apps to your notes'),
        findsOneWidget,
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }

    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          keyStorageProvider.overrideWithValue(keyStorage),
          pinEnabledProvider.overrideWith((ref) async => false),
        ],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('AI Apps'), findsNothing);
    expect(
      find.text('Connect MCP-compatible apps to your notes'),
      findsNothing,
    );

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('failed PIN removal clears browser text input before exit',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final keyStorage = _FakeKeyStorage();
    final pinAuth = _RejectingPinAuth(keyStorage);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          keyStorageProvider.overrideWithValue(keyStorage),
          pinAuthProvider.overrideWithValue(pinAuth),
          pinEnabledProvider.overrideWith((ref) async => true),
        ],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.text('PIN Lock'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Remove PIN'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final pinFieldFinder = find.widgetWithText(TextField, 'Current PIN');
    final pinField = tester.widget<TextField>(pinFieldFinder);
    expect(pinField.autofillHints, isNull);

    await tester.enterText(pinFieldFinder, '1111');
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Incorrect PIN'), findsOneWidget);
    expect(pinField.controller?.text, isEmpty);
    expect(tester.testTextInput.editingState?['text'], isEmpty);

    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Remove PIN'), findsNothing);
    expect(tester.testTextInput.hasAnyClients, isFalse);
    expect(tester.testTextInput.editingState?['text'], isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('existing recovery phrase validates before the final step',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: OnboardingScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final continueFinder = find.widgetWithText(FilledButton, 'Continue');
    tester.widgetList<FilledButton>(continueFinder).first.onPressed!();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use Existing'));
    await tester.pump();
    await tester.enterText(
      find.widgetWithText(TextField, 'Recovery Phrase'),
      'one two three',
    );

    tester.widgetList<FilledButton>(continueFinder).first.onPressed!();
    await tester.pump();

    expect(
      find.text(
        'Invalid recovery phrase. Please check your words and try again.',
      ),
      findsOneWidget,
    );
    expect(find.text('You\'re ready to go!'), findsNothing);
  });

  testWidgets('new-vault onboarding requires recovery phrase acknowledgement',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: OnboardingScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('Link from Trusted Device'), findsOneWidget);
    expect(find.bySemanticsLabel('Continue'), findsOneWidget);

    final continueFinder = find.widgetWithText(FilledButton, 'Continue');
    tester.widgetList<FilledButton>(continueFinder).first.onPressed!();
    await tester.pumpAndSettle();

    expect(find.text('I saved this recovery phrase'), findsOneWidget);
    expect(find.bySemanticsLabel('Continue'), findsOneWidget);
    var continueButtons = tester
        .widgetList<FilledButton>(
          find.widgetWithText(FilledButton, 'Continue'),
        )
        .toList();
    expect(continueButtons, isNotEmpty);
    expect(continueButtons.every((button) => button.onPressed == null), isTrue);

    final acknowledgement =
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile));
    acknowledgement.onChanged!(true);
    await tester.pump();

    continueButtons = tester
        .widgetList<FilledButton>(
          find.widgetWithText(FilledButton, 'Continue'),
        )
        .toList();
    expect(continueButtons, isNotEmpty);
    expect(continueButtons.every((button) => button.onPressed != null), isTrue);

    continueButtons.first.onPressed!();
    await tester.pumpAndSettle();

    expect(find.text('IMPORTANT: Save your recovery kit!'), findsNothing);
    final completionHeading = find.text('You\'re ready to go!');
    expect(completionHeading, findsOneWidget);
    expect(tester.getTopLeft(completionHeading).dy, lessThan(420));
    semantics.dispose();
  });
}

Finder _formField(String label) {
  return find.widgetWithText(TextFormField, label).first;
}

Finder _semanticsWidgetWithLabel(String label) {
  return find.byWidgetPredicate(
    (widget) => widget is Semantics && widget.properties.label == label,
  );
}

Note _note(String uuid, String title, DateTime timestamp) {
  return Note(
    uuid: uuid,
    title: title,
    content: '$title content',
    createdAt: timestamp,
    modifiedAt: timestamp,
  );
}

class _RecordingNotesRepository extends NotesRepository {
  Note? savedNote;
  List<String>? reorderedUuids;
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

  @override
  Future<void> reorderNotes(List<String> orderedUuids) async {
    reorderedUuids = List<String>.from(orderedUuids);
    final existing = Map<String, Note>.from(notes);
    notes
      ..clear()
      ..addEntries(
        orderedUuids
            .where(existing.containsKey)
            .map((uuid) => MapEntry(uuid, existing.remove(uuid)!)),
      )
      ..addAll(existing);
  }
}

class _FakeKeyStorage extends KeyStorage {
  String? _deviceId;
  String? _deviceName;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> hasDuressKey() async => false;

  @override
  Future<bool> hasGitHubCredentials() async => false;

  @override
  Future<String?> getDeviceId() async => _deviceId;

  @override
  Future<void> storeDeviceId(String deviceId) async {
    _deviceId = deviceId;
  }

  @override
  Future<String?> getLocalDeviceName() async => _deviceName;

  @override
  Future<void> storeLocalDeviceName(String name) async {
    _deviceName = name;
  }

  @override
  Future<String?> getGitHubToken() async => null;

  @override
  Future<String?> getRepoOwner() async => null;

  @override
  Future<String?> getRepoName() async => null;

  @override
  Future<String?> getDeviceRegistrationMethod() async => null;

  @override
  Future<String?> getDismissedUnverifiedDeviceIds() async => null;

  @override
  Future<String?> getDeviceRegistry() async => null;
}

class _RejectingPinAuth extends PinAuth {
  _RejectingPinAuth(KeyStorage keyStorage) : super(keyStorage: keyStorage);

  @override
  Future<bool> verifyPin(String pin) async => false;
}
