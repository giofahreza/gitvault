import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitvault/core/crypto/crypto_manager.dart';
import 'package:gitvault/core/session/vault_session_controller.dart';
import 'package:gitvault/data/repositories/notes_repository.dart';
import 'package:gitvault/mcp/mcp_approval_controller.dart';
import 'package:gitvault/mcp/mcp_client_registry.dart';
import 'package:gitvault/mcp/mcp_models.dart';
import 'package:gitvault/mcp/notes_mcp_service.dart';
import 'package:hive/hive.dart';

import '../support/memory_registry_storage.dart';
import 'test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late McpClientRegistry registry;
  late McpApprovalController approvals;
  late VaultSessionState session;

  setUpAll(() async {
    directory = await initializeTestHive();
  });
  setUp(() async {
    await resetMcpBoxes();
    if (Hive.isBoxOpen('notes')) await Hive.box<String>('notes').close();
    await Hive.deleteBoxFromDisk('notes');
    registry = McpClientRegistry();
    await registry.setEnabled(true);
    approvals = McpApprovalController();
    session = VaultSessionState(
        status: VaultSessionStatus.unlocked,
        changedAt: DateTime.now(),
        generation: 1);
  });
  tearDown(() async {
    approvals.dispose();
    registry.dispose();
    if (Hive.isBoxOpen('notes')) await Hive.box<String>('notes').close();
    await resetMcpBoxes();
  });
  tearDownAll(() => closeTestHive(directory));

  NotesMcpService service(NotesRepository repository,
          {void Function()? onMutation}) =>
      NotesMcpService(
          notesRepository: repository,
          registry: registry,
          approvalController: approvals,
          readSession: () => session,
          onMutation: onMutation);

  Future<String> client(
    Set<McpPermission> permissions, {
    Set<String> allowed = const {},
    Set<String> denied = const {},
    McpWritePolicy policy = McpWritePolicy.allowWhileUnlocked,
  }) async =>
      (await registry.createClient(
        displayName: 'Test app',
        transport: McpClientTransport.streamableHttp,
        permissions: permissions,
        allowedTags: allowed,
        deniedTags: denied,
        writePolicy: policy,
      ))
          .client
          .id;

  final denied = isA<McpOperationException>()
      .having((e) => e.code, 'code', 'permission_denied');

  // Every permission is checked against every operation category. Each test
  // starts with a fresh note, avoiding permission success hidden by prior CRUD.
  for (final grant in [null, ...McpPermission.values]) {
    for (final required in McpPermission.values
        .where((p) => p != McpPermission.includeArchived)) {
      test('MCP-GAP-002 grant=$grant operation=$required', () async {
        final note = testNote(id: 'n1', title: 'Matrix', tags: ['work']);
        final repository = MemoryNotesRepository([note]);
        final notes = service(repository);
        final id = await client({if (grant != null) grant});
        approvals.addListener(() {
          final pending = approvals.nextRequest;
          if (pending != null)
            approvals.resolve(pending.id, McpApprovalDecision.allowOnce);
        });
        final version = note.modifiedAt.toUtc().toIso8601String();
        final Future<Object?> operation = switch (required) {
          McpPermission.readMetadata => notes.listNotes(clientId: id),
          McpPermission.readContent =>
            notes.getNote(clientId: id, noteId: 'n1'),
          McpPermission.search =>
            notes.searchNotes(clientId: id, query: 'Matrix'),
          McpPermission.create =>
            notes.createNote(clientId: id, title: 'New', content: 'Body'),
          McpPermission.append => notes.appendToNote(
              clientId: id,
              noteId: 'n1',
              text: 'Append',
              expectedModifiedAt: version),
          McpPermission.edit => notes.updateNote(
              clientId: id,
              noteId: 'n1',
              title: 'Edited',
              expectedModifiedAt: version),
          McpPermission.archive => notes.archiveNote(
              clientId: id, noteId: 'n1', expectedModifiedAt: version),
          McpPermission.delete => notes.deleteNote(
              clientId: id, noteId: 'n1', expectedModifiedAt: version),
          _ => throw StateError('Unexpected permission'),
        };
        if (grant == required) {
          expect(await operation, isA<Map>());
        } else {
          await expectLater(operation, throwsA(denied));
          expect(repository.notes, {'n1': note});
          expect(approvals.pending, isEmpty);
        }
      });
    }
  }

  for (final allowed in [
    <String>{},
    {'work'}
  ]) {
    for (final deniedTags in [
      <String>{},
      {'private'},
      {'work'}
    ]) {
      test(
          'MCP-GAP-002 tag allow=$allowed deny=$deniedTags applies to read/write',
          () async {
        final repository = MemoryNotesRepository([
          testNote(id: 'work', title: 'Work', tags: ['work']),
          testNote(id: 'private', title: 'Private', tags: ['private']),
          testNote(id: 'both', title: 'Both', tags: ['work', 'private']),
          testNote(id: 'none', title: 'None'),
        ]);
        final notes = service(repository);
        final id = await client(McpPermission.values.toSet(),
            allowed: allowed, denied: deniedTags);
        final visible = (await notes.listNotes(clientId: id))['notes'] as List;
        final expected = repository.notes.values
            .where((n) =>
                (allowed.isEmpty || n.tags.any(allowed.contains)) &&
                !n.tags.any(deniedTags.contains))
            .map((n) => n.uuid)
            .toSet();
        expect(visible.map((n) => n['uuid']).toSet(), expected);
        final writable = (allowed.isEmpty || allowed.contains('work')) &&
            !deniedTags.contains('work');
        final create = notes.createNote(
            clientId: id, title: 'Scoped', content: 'Body', tags: ['work']);
        if (writable) {
          final created = (await create)['note'] as Map;
          expect(created['tags'], ['work']);
          if (deniedTags.contains('private')) {
            await expectLater(
                notes.updateNote(
                    clientId: id,
                    noteId: created['uuid'] as String,
                    expectedModifiedAt: created['modified_at'] as String,
                    tags: ['private']),
                throwsA(isA<McpOperationException>()));
          }
        } else {
          await expectLater(create, throwsA(isA<McpOperationException>()));
        }
      });
    }
  }

  for (final pagination in [(-1, 25), (0, 0), (0, 101)]) {
    test('MCP-GAP-001 rejects invalid pagination $pagination', () async {
      final id =
          await client({McpPermission.readMetadata, McpPermission.search});
      final notes = service(MemoryNotesRepository([]));
      for (final operation in [
        notes.listNotes(
            clientId: id, offset: pagination.$1, limit: pagination.$2),
        notes.searchNotes(
            clientId: id,
            query: 'x',
            offset: pagination.$1,
            limit: pagination.$2),
      ]) {
        await expectLater(
            operation,
            throwsA(isA<McpOperationException>()
                .having((e) => e.code, 'code', 'invalid_input')));
      }
    });
  }

  test('MCP-GAP-001 pagination boundaries are complete without duplicate notes',
      () async {
    final id = await client({McpPermission.readMetadata});
    final notes = service(MemoryNotesRepository([
      for (var i = 0; i < 103; i++) testNote(id: 'n$i', title: 'Note $i'),
    ]));
    final first = await notes.listNotes(clientId: id, limit: 100);
    final second = await notes.listNotes(clientId: id, offset: 100, limit: 100);
    expect((first['notes'] as List), hasLength(100));
    expect((second['notes'] as List), hasLength(3));
    final ids = [...first['notes'] as List, ...second['notes'] as List]
        .map((n) => n['uuid'])
        .toSet();
    expect(ids, hasLength(103));
    expect(
        (await notes.listNotes(clientId: id, offset: 104))['notes'], isEmpty);
  });

  for (final invalid in ['title', 'content', 'query', 'tags', 'color']) {
    test('MCP-GAP-001 invalid $invalid cannot mutate notes', () async {
      final id = await client(McpPermission.values.toSet());
      final repository = MemoryNotesRepository([]);
      final notes = service(repository);
      final operation = invalid == 'query'
          ? notes.searchNotes(clientId: id, query: 'x' * 501)
          : notes.createNote(
              clientId: id,
              title: invalid == 'title' ? 'x' * 501 : 'Valid',
              content: invalid == 'content' ? 'x' * (256 * 1024 + 1) : 'Body',
              tags: invalid == 'tags' ? List.generate(51, (i) => 't$i') : [],
              color: invalid == 'color' ? 'future-color' : 'white');
      await expectLater(
          operation,
          throwsA(isA<McpOperationException>()
              .having((e) => e.code, 'code', 'invalid_input')));
      expect(repository.notes, isEmpty);
    });
  }

  test('MCP-GAP-006 persisted activity prunes age/count and excludes bodies',
      () async {
    final box = await Hive.openBox<String>(McpClientRegistry.activityBoxName);
    await box.putAll({
      for (var i = 0; i < 1005; i++)
        'recent-$i': jsonEncode(McpActivityRecord(
          id: 'recent-$i',
          timestamp: DateTime.now().subtract(Duration(seconds: i)),
          clientId: 'c',
          clientName: 'App',
          action: 'get_note',
          result: McpActivityResult.allowed,
          approvalRequested: false,
        ).toJson()),
      'expired': jsonEncode(McpActivityRecord(
              id: 'expired',
              timestamp: DateTime.now().subtract(const Duration(days: 31)),
              clientId: 'c',
              clientName: 'App',
              action: 'get_note',
              result: McpActivityResult.allowed,
              approvalRequested: false)
          .toJson()),
      'broken': '{invalid-json',
    });
    final loaded = McpClientRegistry();
    await loaded.initialize();
    expect(loaded.activity, hasLength(1000));
    expect(loaded.activity.map((r) => r.id), isNot(contains('expired')));
    expect(loaded.activity.first.id, 'recent-0');
    loaded.dispose();

    final id = await client({McpPermission.create});
    final notes = service(MemoryNotesRepository([]));
    await notes.createNote(
        clientId: id, title: 'title-canary', content: 'body-canary');
    final persisted = box.values.join();
    expect(persisted, isNot(contains('body-canary')));
    expect(persisted, isNot(contains('title-canary')));
    expect(persisted, isNot(contains(registry.getClient(id)!.tokenVerifier)));
  });

  test('MCP-GAP-005 allow-once prompts again and permission loss cancels write',
      () async {
    final id = await client({McpPermission.create},
        policy: McpWritePolicy.askEveryTime);
    final repository = MemoryNotesRepository([]);
    final notes = service(repository);
    Future<void> waitApproval() async {
      for (var i = 0; i < 100 && approvals.nextRequest == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(approvals.nextRequest, isNotNull);
    }

    final first = notes.createNote(clientId: id, title: 'First', content: 'A');
    await waitApproval();
    approvals.resolve(approvals.nextRequest!.id, McpApprovalDecision.allowOnce);
    await first;
    expect(registry.getClient(id)!.approvalExemptPermissions, isEmpty);
    final next = notes.createNote(clientId: id, title: 'Next', content: 'B');
    final failed = expectLater(next, throwsA(denied));
    await waitApproval();
    await registry.updateClient(id, permissions: {});
    approvals.resolve(approvals.nextRequest!.id, McpApprovalDecision.allowOnce);
    await failed;
    expect(repository.notes, hasLength(1));
  });

  test(
      'MCP-GAP-008/010 real encrypted CRUD persists offline and schedules mutations',
      () async {
    final storage = MemoryRegistryStorage();
    final crypto = CryptoManager();
    storage.root = crypto.generateRandomKey();
    var repository =
        NotesRepository(cryptoManager: crypto, keyStorage: storage);
    var mutations = 0;
    var notes = service(repository, onMutation: () {
      mutations++;
    });
    final id = await client(McpPermission.values.toSet());
    final created = (await notes.createNote(
        clientId: id,
        title: 'encrypted-title-canary',
        content: 'encrypted-body-canary'))['note'] as Map;
    final uuid = created['uuid'] as String;
    final raw = Hive.box<String>('notes').values.join();
    expect(raw, isNot(contains('encrypted-body-canary')));
    expect(raw, isNot(contains('encrypted-title-canary')));
    final updated = (await notes.updateNote(
        clientId: id,
        noteId: uuid,
        expectedModifiedAt: created['modified_at'] as String,
        content: 'Edited'))['note'] as Map;
    final appended = (await notes.appendToNote(
        clientId: id,
        noteId: uuid,
        expectedModifiedAt: updated['modified_at'] as String,
        text: 'Append'))['note'] as Map;
    await Hive.box<String>('notes').close();
    repository = NotesRepository(cryptoManager: crypto, keyStorage: storage);
    await repository.initialize();
    expect((await repository.getNote(uuid))!.content, 'Edited\nAppend');
    notes = service(repository, onMutation: () {
      mutations++;
    });
    final archived = (await notes.archiveNote(
        clientId: id,
        noteId: uuid,
        expectedModifiedAt: appended['modified_at'] as String))['note'] as Map;
    approvals.addListener(() {
      final request = approvals.nextRequest;
      if (request != null)
        approvals.resolve(request.id, McpApprovalDecision.allowOnce);
    });
    await notes.deleteNote(
        clientId: id,
        noteId: uuid,
        expectedModifiedAt: archived['modified_at'] as String);
    expect(await repository.getNote(uuid), isNull);
    expect(mutations, 5);
    await Hive.box<String>('notes').close();
    final reopened =
        NotesRepository(cryptoManager: crypto, keyStorage: storage);
    await reopened.initialize();
    expect(await reopened.getNote(uuid), isNull);
  });

  for (final policy in McpWritePolicy.values) {
    for (final decision in McpApprovalDecision.values) {
      for (final action in [
        'create',
        'append',
        'edit',
        'section',
        'daily-create',
        'daily-append-new',
        'daily-append-existing',
        'archive',
        'delete'
      ]) {
        test('MCP-GAP-005 approval $action $policy $decision', () async {
          final original = testNote(
              id: 'original',
              title: 'Original',
              content: '# Heading\nBody',
              tags: ['work']);
          final daily = testNote(id: 'daily', title: 'Daily').copyWith(
              journalDate: DateTime.utc(2026, 11, 23), tags: ['journal']);
          final repository = MemoryNotesRepository([
            original,
            if (action == 'daily-append-existing') daily,
          ]);
          final before = Map.of(repository.notes);
          final notes = service(repository);
          final id = await client(McpPermission.values.toSet(), policy: policy);
          var prompts = 0;
          approvals.addListener(() {
            final request = approvals.nextRequest;
            if (request != null) {
              prompts++;
              if (decision == McpApprovalDecision.cancelled) {
                approvals.cancelForClient(id);
              } else {
                approvals.resolve(request.id, decision);
              }
            }
          });
          final version = original.modifiedAt.toUtc().toIso8601String();
          final write = switch (action) {
            'create' =>
              notes.createNote(clientId: id, title: 'New', content: 'Body'),
            'append' => notes.appendToNote(
                clientId: id,
                noteId: original.uuid,
                expectedModifiedAt: version,
                text: 'Append'),
            'edit' => notes.updateNote(
                clientId: id,
                noteId: original.uuid,
                expectedModifiedAt: version,
                content: 'Changed'),
            'section' => notes.updateNoteSection(
                clientId: id,
                noteId: original.uuid,
                expectedModifiedAt: version,
                heading: 'Heading',
                content: 'Changed'),
            'daily-create' => notes.getOrCreateDailyNote(
                clientId: id, date: '2026-11-23', template: 'Template'),
            'daily-append-new' ||
            'daily-append-existing' =>
              notes.appendToDailyNote(
                  clientId: id,
                  date: '2026-11-23',
                  text: 'Append',
                  expectedModifiedAt: action == 'daily-append-existing'
                      ? daily.modifiedAt.toUtc().toIso8601String()
                      : null),
            'archive' => notes.archiveNote(
                clientId: id,
                noteId: original.uuid,
                expectedModifiedAt: version),
            _ => notes.deleteNote(
                clientId: id,
                noteId: original.uuid,
                expectedModifiedAt: version),
          };
          final needsPrompt =
              policy == McpWritePolicy.askEveryTime || action == 'delete';
          final accepted = !needsPrompt ||
              decision == McpApprovalDecision.allowOnce ||
              decision == McpApprovalDecision.allowAlways;
          if (accepted) {
            expect(await write, isA<Map>());
            expect(repository.notes, isNot(equals(before)));
          } else {
            await expectLater(
                write,
                throwsA(isA<McpOperationException>().having(
                    (e) => e.code,
                    'code',
                    decision == McpApprovalDecision.timeout
                        ? 'approval_timeout'
                        : 'approval_denied')));
            expect(repository.notes, before);
          }
          expect(prompts, needsPrompt ? 1 : 0);
          final exemptions = registry.getClient(id)!.approvalExemptPermissions;
          expect(
              exemptions.isNotEmpty,
              needsPrompt &&
                  action != 'delete' &&
                  decision == McpApprovalDecision.allowAlways);
          expect(exemptions, isNot(contains(McpPermission.delete)));
          expect(approvals.pending, isEmpty);
        });
      }
    }
  }

  for (final terminal in [
    VaultSessionStatus.locked,
    VaultSessionStatus.duress,
    VaultSessionStatus.revoked
  ]) {
    test('MCP-GAP-012 $terminal during encryption prevents actual persistence',
        () async {
      final crypto = _GatedCrypto();
      final storage = MemoryRegistryStorage();
      storage.root = crypto.generateRandomKey();
      final repository =
          NotesRepository(cryptoManager: crypto, keyStorage: storage);
      final notes = service(repository);
      final id = await client({McpPermission.create});
      crypto.block = true;
      final write = notes.createNote(
          clientId: id, title: 'Must not persist', content: 'Secret');
      final rejected = expectLater(
          write,
          throwsA(isA<McpOperationException>()
              .having((e) => e.code, 'code', 'vault_locked')));
      await crypto.started.future;
      session = VaultSessionState(
          status: terminal, changedAt: DateTime.now(), generation: 2);
      crypto.release.complete();
      await rejected;
      expect(await repository.getAllStoredNotes(), isEmpty);
      expect(Hive.box<String>('notes').isEmpty, true);
    });
  }

  for (final action in [
    'create',
    'append',
    'edit',
    'section',
    'daily-create',
    'daily-append-new',
    'daily-append-existing',
    'archive'
  ]) {
    for (final transition in [
      'lock',
      'duress',
      'revoke-device',
      'revoke-client',
      'permissions',
      'tags',
      'policy'
    ]) {
      test(
          'MCP-GAP-012 encrypted $action rejects $transition before persistence',
          () async {
        final crypto = _GatedCrypto();
        final storage = MemoryRegistryStorage()
          ..root = crypto.generateRandomKey();
        final repository =
            NotesRepository(cryptoManager: crypto, keyStorage: storage);
        await repository.initialize();
        final original = await repository.createNote(
            title: 'Original', content: '# Heading\nBody', tags: ['work']);
        final daily = action == 'daily-append-existing'
            ? await repository.createNote(
                title: 'Daily',
                content: 'Daily body',
                tags: ['journal'],
                journalDate: DateTime.utc(2026, 11, 23))
            : null;
        final before = Map.of(Hive.box<String>('notes').toMap());
        var mutations = 0;
        final notes = service(repository, onMutation: () => mutations++);
        final id = await client(McpPermission.values.toSet());
        crypto.block = true;
        final version = original.modifiedAt.toUtc().toIso8601String();
        final write = switch (action) {
          'create' =>
            notes.createNote(clientId: id, title: 'New', content: 'Secret'),
          'append' => notes.appendToNote(
              clientId: id,
              noteId: original.uuid,
              expectedModifiedAt: version,
              text: 'Append'),
          'edit' => notes.updateNote(
              clientId: id,
              noteId: original.uuid,
              expectedModifiedAt: version,
              content: 'Changed'),
          'section' => notes.updateNoteSection(
              clientId: id,
              noteId: original.uuid,
              expectedModifiedAt: version,
              heading: 'Heading',
              content: 'Changed'),
          'daily-create' => notes.getOrCreateDailyNote(
              clientId: id, date: '2026-11-23', template: 'Template'),
          'daily-append-new' ||
          'daily-append-existing' =>
            notes.appendToDailyNote(
                clientId: id,
                date: '2026-11-23',
                text: 'Append',
                expectedModifiedAt:
                    daily?.modifiedAt.toUtc().toIso8601String()),
          _ => notes.archiveNote(
              clientId: id, noteId: original.uuid, expectedModifiedAt: version),
        };
        final rejected =
            expectLater(write, throwsA(isA<McpOperationException>()));
        await crypto.started.future.timeout(const Duration(seconds: 5));
        switch (transition) {
          case 'lock' || 'duress' || 'revoke-device':
            session = VaultSessionState(
                status: switch (transition) {
                  'lock' => VaultSessionStatus.locked,
                  'duress' => VaultSessionStatus.duress,
                  _ => VaultSessionStatus.revoked,
                },
                changedAt: DateTime.now(),
                generation: 2);
          case 'revoke-client':
            await registry.revokeClient(id);
          case 'permissions':
            await registry.updateClient(id, permissions: {});
          case 'tags':
            await registry.updateClient(id, deniedTags: {'work', 'journal'});
          case 'policy':
            await registry.updateClient(id,
                writePolicy: McpWritePolicy.askEveryTime);
        }
        crypto.release.complete();
        await rejected;
        expect(Hive.box<String>('notes').toMap(), before);
        expect(mutations, 0);
        expect(approvals.pending, isEmpty);
      });
    }
  }

  for (final action in [
    'list',
    'search',
    'get',
    'tags',
    'link',
    'backlinks',
    'outline',
    'block'
  ]) {
    for (final transition in [
      'lock',
      'duress',
      'revoke-device',
      'revoke-client',
      'permissions',
      'tags',
      'policy'
    ]) {
      test(
          'MCP-GAP-012 real $action read rejects $transition during decryption',
          () async {
        final crypto = _GatedCrypto();
        final storage = MemoryRegistryStorage()
          ..root = crypto.generateRandomKey();
        final repository =
            NotesRepository(cryptoManager: crypto, keyStorage: storage);
        await repository.initialize();
        final original = await repository.createNote(
            title: 'Original',
            content: '# Heading\nbody-read-canary ^block1',
            tags: ['work']);
        final notes = service(repository);
        final id = await client(McpPermission.values.toSet());
        crypto.blockRead = true;
        final read = switch (action) {
          'list' => notes.listNotes(clientId: id),
          'search' => notes.searchNotes(clientId: id, query: 'Original'),
          'get' => notes.getNote(clientId: id, noteId: original.uuid),
          'tags' => notes.listNoteTags(clientId: id),
          'link' => notes.resolveNoteLink(clientId: id, query: 'Original'),
          'backlinks' =>
            notes.listBacklinks(clientId: id, noteId: original.uuid),
          'outline' =>
            notes.getNoteOutline(clientId: id, noteId: original.uuid),
          _ => notes.resolveBlockReference(clientId: id, blockId: 'block1'),
        };
        final rejected =
            expectLater(read, throwsA(isA<McpOperationException>()));
        await crypto.started.future.timeout(const Duration(seconds: 5));
        switch (transition) {
          case 'lock' || 'duress' || 'revoke-device':
            session = VaultSessionState(
                status: switch (transition) {
                  'lock' => VaultSessionStatus.locked,
                  'duress' => VaultSessionStatus.duress,
                  _ => VaultSessionStatus.revoked,
                },
                changedAt: DateTime.now(),
                generation: 2);
          case 'revoke-client':
            await registry.revokeClient(id);
          case 'permissions':
            await registry.updateClient(id, permissions: {});
          case 'tags':
            await registry.updateClient(id, deniedTags: {'work'});
          case 'policy':
            await registry.updateClient(id,
                writePolicy: McpWritePolicy.askEveryTime);
        }
        crypto.blockRead = false;
        crypto.release.complete();
        await rejected;
        expect(approvals.pending, isEmpty);
      });
    }
  }

  for (final transition in [
    'lock',
    'duress',
    'revoke-device',
    'revoke-client',
    'permissions',
    'tags',
    'policy'
  ]) {
    test('MCP-GAP-012 queued actual delete rejects $transition at persistence',
        () async {
      final crypto = _GatedCrypto();
      final storage = MemoryRegistryStorage()
        ..root = crypto.generateRandomKey();
      final repository =
          NotesRepository(cryptoManager: crypto, keyStorage: storage);
      await repository.initialize();
      final original = await repository
          .createNote(title: 'Keep', content: 'Body', tags: ['work']);
      final notes = service(repository);
      final id = await client(McpPermission.values.toSet());
      crypto.block = true;
      final holdingWrite =
          repository.createNote(title: 'Queue holder', content: 'Body');
      await crypto.started.future;
      var approved = false;
      approvals.addListener(() {
        final request = approvals.nextRequest;
        if (request != null) {
          approved = true;
          approvals.resolve(request.id, McpApprovalDecision.allowOnce);
        }
      });
      final deleting = notes.deleteNote(
          clientId: id,
          noteId: original.uuid,
          expectedModifiedAt: original.modifiedAt.toUtc().toIso8601String());
      final rejected =
          expectLater(deleting, throwsA(isA<McpOperationException>()));
      for (var i = 0; i < 100 && !approved; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(approved, true);
      switch (transition) {
        case 'lock' || 'duress' || 'revoke-device':
          session = VaultSessionState(
              status: switch (transition) {
                'lock' => VaultSessionStatus.locked,
                'duress' => VaultSessionStatus.duress,
                _ => VaultSessionStatus.revoked,
              },
              changedAt: DateTime.now(),
              generation: 2);
        case 'revoke-client':
          await registry.revokeClient(id);
        case 'permissions':
          await registry.updateClient(id, permissions: {});
        case 'tags':
          await registry.updateClient(id, deniedTags: {'work'});
        case 'policy':
          await registry.updateClient(id,
              writePolicy: McpWritePolicy.askEveryTime);
      }
      crypto.release.complete();
      await holdingWrite;
      await rejected;
      expect((await repository.getNote(original.uuid))!.content, 'Body');
      expect((await repository.getAllStoredNotes()).length, 2);
    });
  }
}

class _GatedCrypto extends CryptoManager {
  bool block = false;
  bool blockRead = false;
  final started = Completer<void>();
  final release = Completer<void>();
  @override
  Future<Uint8List> decryptXChaCha20(
      {required EncryptedBox box, required Uint8List key}) async {
    final data = await super.decryptXChaCha20(box: box, key: key);
    if (blockRead) {
      started.complete();
      await release.future;
    }
    return data;
  }

  @override
  Future<EncryptedBox> encryptXChaCha20(
      {required Uint8List data, required Uint8List key}) async {
    final box = await super.encryptXChaCha20(data: data, key: key);
    if (block) {
      started.complete();
      await release.future;
    }
    return box;
  }
}
