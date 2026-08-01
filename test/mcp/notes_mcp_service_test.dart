import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitvault/core/session/vault_session_controller.dart';
import 'package:gitvault/data/models/note.dart';
import 'package:gitvault/data/repositories/notes_repository.dart';
import 'package:gitvault/mcp/mcp_approval_controller.dart';
import 'package:gitvault/mcp/mcp_client_registry.dart';
import 'package:gitvault/mcp/mcp_models.dart';
import 'package:gitvault/mcp/notes_mcp_service.dart';

import 'test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory hiveDirectory;
  late McpClientRegistry registry;
  late McpApprovalController approvals;
  late VaultSessionState session;

  setUpAll(() async {
    hiveDirectory = await initializeTestHive();
  });

  setUp(() async {
    await resetMcpBoxes();
    registry = McpClientRegistry();
    await registry.setEnabled(true);
    approvals = McpApprovalController();
    session = VaultSessionState(
      status: VaultSessionStatus.unlocked,
      changedAt: DateTime.now(),
      generation: 1,
    );
  });

  tearDown(() async {
    approvals.dispose();
    await resetMcpBoxes();
  });

  tearDownAll(() async {
    await closeTestHive(hiveDirectory);
  });

  test('lock and tag scope prevent note access', () async {
    final repository = MemoryNotesRepository([
      testNote(id: 'work', title: 'Work', tags: const ['work']),
      testNote(id: 'private', title: 'Private', tags: const ['private']),
    ]);
    final issued = await registry.createClient(
      displayName: 'Scoped reader',
      transport: McpClientTransport.streamableHttp,
      permissions: const {McpPermission.readMetadata},
      allowedTags: const {'work'},
      deniedTags: const {'private'},
    );
    final service = NotesMcpService(
      notesRepository: repository,
      registry: registry,
      approvalController: approvals,
      readSession: () => session,
    );

    final result = await service.listNotes(clientId: issued.client.id);
    expect(
      (result['notes'] as List).map((note) => (note as Map)['uuid']),
      ['work'],
    );

    session = VaultSessionState(
      status: VaultSessionStatus.locked,
      changedAt: DateTime.now(),
      generation: 2,
    );
    await expectLater(
      service.listNotes(clientId: issued.client.id),
      throwsA(
        isA<McpOperationException>()
            .having((error) => error.code, 'code', 'vault_locked'),
      ),
    );
  });

  test('search includes archived notes only with permission', () async {
    final repository = MemoryNotesRepository([
      testNote(id: 'active', title: 'Project alpha'),
      testNote(id: 'archived', title: 'Project archive', archived: true),
    ]);
    final issued = await registry.createClient(
      displayName: 'Searcher',
      transport: McpClientTransport.streamableHttp,
      permissions: const {
        McpPermission.search,
        McpPermission.includeArchived,
      },
    );
    final service = NotesMcpService(
      notesRepository: repository,
      registry: registry,
      approvalController: approvals,
      readSession: () => session,
    );

    final result = await service.searchNotes(
      clientId: issued.client.id,
      query: 'project',
    );
    expect(result['total'], 2);
  });

  test('search does not inspect note bodies without content permission',
      () async {
    final repository = MemoryNotesRepository([
      testNote(
        id: 'secret',
        title: 'Ordinary title',
        content: 'Project nightingale is confidential',
        tags: const ['work'],
      ),
    ]);
    final metadataOnly = await registry.createClient(
      displayName: 'Metadata searcher',
      transport: McpClientTransport.streamableHttp,
      permissions: const {McpPermission.search},
    );
    final contentReader = await registry.createClient(
      displayName: 'Content searcher',
      transport: McpClientTransport.streamableHttp,
      permissions: const {
        McpPermission.search,
        McpPermission.readContent,
      },
    );
    final service = NotesMcpService(
      notesRepository: repository,
      registry: registry,
      approvalController: approvals,
      readSession: () => session,
    );

    final metadataResult = await service.searchNotes(
      clientId: metadataOnly.client.id,
      query: 'nightingale',
    );
    expect(metadataResult['total'], 0);

    final contentResult = await service.searchNotes(
      clientId: contentReader.client.id,
      query: 'nightingale',
    );
    expect(contentResult['total'], 1);
    expect(
      ((contentResult['notes'] as List).single as Map)['content'],
      contains('nightingale'),
    );
  });

  test('a note changed during approval returns conflict', () async {
    final original = testNote(id: 'note', title: 'Original');
    final repository = MemoryNotesRepository([original]);
    final issued = await registry.createClient(
      displayName: 'Editor',
      transport: McpClientTransport.streamableHttp,
      permissions: const {McpPermission.edit},
    );
    final service = NotesMcpService(
      notesRepository: repository,
      registry: registry,
      approvalController: approvals,
      readSession: () => session,
    );

    final update = service.updateNote(
      clientId: issued.client.id,
      noteId: original.uuid,
      expectedModifiedAt: original.modifiedAt.toUtc().toIso8601String(),
      title: 'MCP edit',
    );
    await Future<void>.delayed(Duration.zero);
    expect(approvals.pending, hasLength(1));

    repository.replace(
      original.copyWith(
        title: 'User edit',
        modifiedAt: original.modifiedAt.add(const Duration(seconds: 1)),
      ),
    );
    approvals.resolve(
      approvals.pending.single.id,
      McpApprovalDecision.allowOnce,
    );

    await expectLater(
      update,
      throwsA(
        isA<McpOperationException>()
            .having((error) => error.code, 'code', 'conflict'),
      ),
    );
    expect(repository.notes['note']!.title, 'User edit');
  });

  test('edit permission without read content does not leak content', () async {
    final original = testNote(
      id: 'note',
      title: 'Original',
      content: 'Sensitive body',
    );
    final repository = MemoryNotesRepository([original]);
    final issued = await registry.createClient(
      displayName: 'Metadata editor',
      transport: McpClientTransport.streamableHttp,
      permissions: const {McpPermission.edit},
      writePolicy: McpWritePolicy.allowWhileUnlocked,
    );
    final service = NotesMcpService(
      notesRepository: repository,
      registry: registry,
      approvalController: approvals,
      readSession: () => session,
    );

    final result = await service.updateNote(
      clientId: issued.client.id,
      noteId: original.uuid,
      expectedModifiedAt: original.modifiedAt.toUtc().toIso8601String(),
      title: 'Renamed',
    );
    final note = result['note'] as Map<String, dynamic>;
    expect(note['title'], 'Renamed');
    expect(note.containsKey('content'), isFalse);
  });

  test('a read that crosses a lock transition returns no note data', () async {
    final repository = _BlockingListNotesRepository([
      testNote(
        id: 'sensitive',
        title: 'Sensitive',
        content: 'Must not cross the lock boundary',
      ),
    ]);
    final issued = await registry.createClient(
      displayName: 'Delayed reader',
      transport: McpClientTransport.streamableHttp,
      permissions: const {McpPermission.readMetadata},
    );
    final service = NotesMcpService(
      notesRepository: repository,
      registry: registry,
      approvalController: approvals,
      readSession: () => session,
    );

    final read = service.listNotes(clientId: issued.client.id);
    await repository.started.future;
    session = VaultSessionState(
      status: VaultSessionStatus.locked,
      changedAt: DateTime.now(),
      generation: 2,
    );
    repository.release.complete();

    await expectLater(
      read,
      throwsA(
        isA<McpOperationException>()
            .having((error) => error.code, 'code', 'vault_locked'),
      ),
    );
  });

  test('a read that crosses client revocation returns no note data', () async {
    final repository = _BlockingListNotesRepository([
      testNote(
        id: 'revoked',
        title: 'Revoked access',
        content: 'Must not cross the authorization boundary',
      ),
    ]);
    final issued = await registry.createClient(
      displayName: 'Revoked reader',
      transport: McpClientTransport.streamableHttp,
      permissions: const {McpPermission.readMetadata},
    );
    final service = NotesMcpService(
      notesRepository: repository,
      registry: registry,
      approvalController: approvals,
      readSession: () => session,
    );

    final read = service.listNotes(clientId: issued.client.id);
    await repository.started.future;
    await registry.revokeClient(issued.client.id);
    repository.release.complete();

    await expectLater(
      read,
      throwsA(
        isA<McpOperationException>()
            .having((error) => error.code, 'code', 'client_revoked'),
      ),
    );
  });

  test('a lock transition during approval prevents the pending write',
      () async {
    final repository = MemoryNotesRepository(const []);
    final issued = await registry.createClient(
      displayName: 'Delayed writer',
      transport: McpClientTransport.streamableHttp,
      permissions: const {McpPermission.create},
    );
    final service = NotesMcpService(
      notesRepository: repository,
      registry: registry,
      approvalController: approvals,
      readSession: () => session,
    );

    final write = service.createNote(
      clientId: issued.client.id,
      title: 'Must not be created',
      content: 'The session changed during approval',
    );
    await Future<void>.delayed(Duration.zero);
    expect(approvals.pending, hasLength(1));

    approvals.resolve(
      approvals.pending.single.id,
      McpApprovalDecision.allowOnce,
    );
    session = VaultSessionState(
      status: VaultSessionStatus.locked,
      changedAt: DateTime.now(),
      generation: 2,
    );
    session = VaultSessionState(
      status: VaultSessionStatus.unlocked,
      changedAt: DateTime.now(),
      generation: 3,
    );

    await expectLater(
      write,
      throwsA(
        isA<McpOperationException>()
            .having((error) => error.code, 'code', 'vault_locked'),
      ),
    );
    expect(repository.notes, isEmpty);
  });

  test('knowledge tools resolve aliases and enforce backlink scope', () async {
    final repository = MemoryNotesRepository([
      testNote(
        id: 'architecture',
        title: 'Architecture',
        content: '# Storage\nDecision. ^storage-decision',
        tags: const ['work'],
      ).copyWith(aliases: const ['System design']),
      testNote(
        id: 'visible-link',
        title: 'Plan',
        content: 'See [[System design#Storage]].',
        tags: const ['work'],
      ),
      testNote(
        id: 'hidden-link',
        title: 'Private plan',
        content: 'See [[Architecture]].',
        tags: const ['private'],
      ),
    ]);
    final issued = await registry.createClient(
      displayName: 'Knowledge reader',
      transport: McpClientTransport.streamableHttp,
      permissions: const {
        McpPermission.readMetadata,
        McpPermission.readContent,
      },
      allowedTags: const {'work'},
    );
    final service = NotesMcpService(
      notesRepository: repository,
      registry: registry,
      approvalController: approvals,
      readSession: () => session,
    );

    final resolution = await service.resolveNoteLink(
      clientId: issued.client.id,
      query: 'System design',
    );
    expect(resolution['status'], 'resolved');
    expect(((resolution['matches'] as List).single as Map)['uuid'],
        'architecture',);

    final backlinks = await service.listBacklinks(
      clientId: issued.client.id,
      noteId: 'architecture',
    );
    final sources = (backlinks['backlinks'] as List)
        .map((item) => ((item as Map)['source'] as Map)['uuid']);
    expect(sources, ['visible-link']);

    final block = await service.resolveBlockReference(
      clientId: issued.client.id,
      blockId: '^storage-decision',
    );
    expect(block['status'], 'resolved');
  });

  test('outline and section update use Markdown heading boundaries', () async {
    final original = testNote(
      id: 'structured',
      title: 'Structured',
      content: '# First\nold\n## Child\nold child\n# Second\nkeep\n',
    );
    final repository = MemoryNotesRepository([original]);
    final issued = await registry.createClient(
      displayName: 'Section editor',
      transport: McpClientTransport.streamableHttp,
      permissions: const {
        McpPermission.readContent,
        McpPermission.edit,
      },
      writePolicy: McpWritePolicy.allowWhileUnlocked,
    );
    final service = NotesMcpService(
      notesRepository: repository,
      registry: registry,
      approvalController: approvals,
      readSession: () => session,
    );

    final outline = await service.getNoteOutline(
      clientId: issued.client.id,
      noteId: original.uuid,
    );
    expect(
      (outline['headings'] as List).map((item) => (item as Map)['anchor']),
      ['first', 'child', 'second'],
    );

    final result = await service.updateNoteSection(
      clientId: issued.client.id,
      noteId: original.uuid,
      expectedModifiedAt: original.modifiedAt.toUtc().toIso8601String(),
      heading: 'first',
      content: 'new body',
    );
    expect(
      (result['note'] as Map)['content'],
      '# First\nnew body\n# Second\nkeep\n',
    );
  });

  test('daily note tools create once and append with concurrency', () async {
    final repository = MemoryNotesRepository(const []);
    final issued = await registry.createClient(
      displayName: 'Journal writer',
      transport: McpClientTransport.streamableHttp,
      permissions: const {
        McpPermission.create,
        McpPermission.append,
        McpPermission.readContent,
      },
      writePolicy: McpWritePolicy.allowWhileUnlocked,
    );
    final service = NotesMcpService(
      notesRepository: repository,
      registry: registry,
      approvalController: approvals,
      readSession: () => session,
    );

    final created = await service.getOrCreateDailyNote(
      clientId: issued.client.id,
      date: '2026-08-01',
      template: '# Journal\n',
    );
    expect(created['created'], isTrue);
    final initial = created['note'] as Map<String, dynamic>;
    expect(initial['journal_date'], startsWith('2026-08-01'));

    final returned = await service.getOrCreateDailyNote(
      clientId: issued.client.id,
      date: '2026-08-01',
    );
    expect(returned['created'], isFalse);

    final appended = await service.appendToDailyNote(
      clientId: issued.client.id,
      date: '2026-08-01',
      text: '- Added by MCP',
      expectedModifiedAt: initial['modified_at'] as String,
    );
    expect(
      ((appended['note'] as Map)['content'] as String),
      contains('- Added by MCP'),
    );
  });

  test('daily note creation handles a concurrent journal safely', () async {
    final existing = testNote(
      id: 'concurrent-journal',
      title: '2026-08-01',
      tags: const ['journal'],
    ).copyWith(journalDate: DateTime.utc(2026, 8, 1));
    final repository = _RacingDailyNotesRepository(existing);
    final issued = await registry.createClient(
      displayName: 'Racing journal writer',
      transport: McpClientTransport.streamableHttp,
      permissions: const {
        McpPermission.create,
        McpPermission.append,
        McpPermission.readContent,
      },
      writePolicy: McpWritePolicy.allowWhileUnlocked,
    );
    var mutations = 0;
    final service = NotesMcpService(
      notesRepository: repository,
      registry: registry,
      approvalController: approvals,
      readSession: () => session,
      onMutation: () => mutations++,
    );

    final returned = await service.getOrCreateDailyNote(
      clientId: issued.client.id,
      date: '2026-08-01',
    );
    expect(returned['created'], isFalse);
    expect((returned['note'] as Map)['uuid'], existing.uuid);
    expect(mutations, 0);

    await expectLater(
      service.appendToDailyNote(
        clientId: issued.client.id,
        date: '2026-08-01',
        text: 'Must not be silently dropped',
      ),
      throwsA(
        isA<McpOperationException>()
            .having((error) => error.code, 'code', 'conflict'),
      ),
    );
    expect(repository.notes[existing.uuid]?.content, existing.content);
    expect(mutations, 0);
  });

  test('templates are never exposed through ordinary MCP note tools', () async {
    final repository = MemoryNotesRepository([
      testNote(id: 'normal', title: 'Normal'),
      testNote(id: 'template', title: 'Secret template')
          .copyWith(isTemplate: true),
    ]);
    final issued = await registry.createClient(
      displayName: 'Reader',
      transport: McpClientTransport.streamableHttp,
      permissions: const {
        McpPermission.readMetadata,
        McpPermission.includeArchived,
      },
    );
    final service = NotesMcpService(
      notesRepository: repository,
      registry: registry,
      approvalController: approvals,
      readSession: () => session,
    );

    final listed = await service.listNotes(clientId: issued.client.id);
    expect(listed['total'], 1);
    expect(((listed['notes'] as List).single as Map)['uuid'], 'normal');
  });
}

class _BlockingListNotesRepository extends MemoryNotesRepository {
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();

  _BlockingListNotesRepository(super.notes);

  @override
  Future<List<Note>> getAllNotes() async {
    started.complete();
    await release.future;
    return super.getAllNotes();
  }
}

class _RacingDailyNotesRepository extends MemoryNotesRepository {
  final Note concurrentNote;

  _RacingDailyNotesRepository(this.concurrentNote) : super([concurrentNote]);

  @override
  Future<Note?> findJournalNote(DateTime date) async => null;

  @override
  Future<JournalNoteResult> getOrCreateJournalNote({
    required DateTime date,
    required String title,
    required String content,
    List<String> tags = const ['journal'],
    List<String> aliases = const [],
    NoteColor color = NoteColor.white,
  }) async {
    return JournalNoteResult(note: concurrentNote, created: false);
  }
}
