import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitvault/core/session/vault_session_controller.dart';
import 'package:gitvault/mcp/mcp_approval_controller.dart';
import 'package:gitvault/mcp/mcp_client_registry.dart';
import 'package:gitvault/mcp/mcp_models.dart';
import 'package:gitvault/mcp/notes_mcp_service.dart';

import 'test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUpAll(() async => directory = await initializeTestHive());
  tearDownAll(() => closeTestHive(directory));

  for (final policy in McpWritePolicy.values) {
    for (final scope in [
      (<String>{}, <String>{}),
      (<String>{'work'}, <String>{}),
      (<String>{}, <String>{'private'}),
      (<String>{'work'}, <String>{'private'}),
      (<String>{'work'}, <String>{'work'}),
      (<String>{'private'}, <String>{}),
    ]) {
      test('MCP-GAP-002 all 512 subsets policy=$policy scope=$scope', () async {
        await resetMcpBoxes();
        final registry = McpClientRegistry();
        final approvals = McpApprovalController();
        addTearDown(() {
          approvals.dispose();
          registry.dispose();
        });
        await registry.setEnabled(true);
        final issued = await registry.createClient(
            displayName: 'Matrix',
            transport: McpClientTransport.streamableHttp,
            permissions: {},
            allowedTags: scope.$1,
            deniedTags: scope.$2,
            writePolicy: policy);
        final id = issued.client.id;
        final repository = MemoryNotesRepository([]);
        final service = NotesMcpService(
            notesRepository: repository,
            registry: registry,
            approvalController: approvals,
            readSession: () => VaultSessionState(
                status: VaultSessionStatus.unlocked,
                changedAt: DateTime.utc(2026),
                generation: 1),
            onMutation: () {});
        var prompts = 0;
        approvals.addListener(() {
          final request = approvals.nextRequest;
          if (request != null) {
            prompts++;
            approvals.resolve(request.id, McpApprovalDecision.allowOnce);
          }
        });
        bool accessible(List<String> tags) =>
            (scope.$1.isEmpty || tags.any(scope.$1.contains)) &&
            !tags.any(scope.$2.contains);
        final visible = accessible(['work']);
        var checks = 0;
        for (var mask = 0; mask < 512; mask++) {
          final permissions = {
            for (var i = 0; i < McpPermission.values.length; i++)
              if (mask & (1 << i) != 0) McpPermission.values[i]
          };
          await registry.updateClient(id, permissions: permissions);
          for (final operation in [
            'list',
            'search',
            'get',
            'archived',
            'create',
            'append',
            'edit',
            'archive',
            'delete',
            'tags-empty',
            'tags-private',
            'tags-both',
            'tag-list',
            'link',
            'backlinks',
            'outline',
            'block',
            'section',
            'daily-create',
            'daily-append-new',
            'daily-append-existing',
          ]) {
            final note = testNote(
                id: 'n',
                title: 'Matrix',
                content: '# Heading\nbody-canary ^block1',
                tags: ['work']);
            repository.notes
              ..clear()
              ..['n'] = note
              ..['a'] = testNote(
                  id: 'a', title: 'Archived', tags: ['work'], archived: true);
            final daily = note.copyWith(
                uuid: 'daily',
                tags: ['journal'],
                journalDate: DateTime.utc(2026, 11, 23));
            if (operation == 'daily-append-existing')
              repository.notes['daily'] = daily;
            final beforeNotes = Map.of(repository.notes);
            final required = switch (operation) {
              'list' || 'tag-list' || 'link' => McpPermission.readMetadata,
              'search' => McpPermission.search,
              'get' ||
              'archived' ||
              'backlinks' ||
              'outline' ||
              'block' =>
                McpPermission.readContent,
              'create' || 'daily-create' => McpPermission.create,
              'append' ||
              'daily-append-new' ||
              'daily-append-existing' =>
                McpPermission.append,
              'archive' => McpPermission.archive,
              'delete' => McpPermission.delete,
              _ => McpPermission.edit,
            };
            final destination = switch (operation) {
              'tags-empty' => <String>[],
              'tags-private' => ['private'],
              'tags-both' => ['work', 'private'],
              'daily-create' ||
              'daily-append-new' ||
              'daily-append-existing' =>
                ['journal'],
              _ => ['work'],
            };
            final version = note.modifiedAt.toUtc().toIso8601String();
            final beforePrompts = prompts;
            final future = switch (operation) {
              'list' => service.listNotes(clientId: id),
              'tag-list' => service.listNoteTags(clientId: id),
              'link' => service.resolveNoteLink(clientId: id, query: 'Matrix'),
              'backlinks' => service.listBacklinks(clientId: id, noteId: 'n'),
              'outline' => service.getNoteOutline(clientId: id, noteId: 'n'),
              'block' =>
                service.resolveBlockReference(clientId: id, blockId: 'block1'),
              'section' => service.updateNoteSection(
                  clientId: id,
                  noteId: 'n',
                  expectedModifiedAt: version,
                  heading: 'Heading',
                  content: 'Edited'),
              'daily-create' => service.getOrCreateDailyNote(
                  clientId: id, date: '2026-11-23', template: 'New body'),
              'daily-append-new' ||
              'daily-append-existing' =>
                service.appendToDailyNote(
                    clientId: id,
                    date: '2026-11-23',
                    text: 'Append',
                    expectedModifiedAt: operation == 'daily-append-existing'
                        ? daily.modifiedAt.toUtc().toIso8601String()
                        : null),
              'search' => service.searchNotes(clientId: id, query: 'Matrix'),
              'get' || 'archived' => service.getNote(
                  clientId: id, noteId: operation == 'get' ? 'n' : 'a'),
              'create' => service.createNote(
                  clientId: id,
                  title: 'New',
                  content: 'New body',
                  tags: destination),
              'append' => service.appendToNote(
                  clientId: id,
                  noteId: 'n',
                  text: 'Appended',
                  expectedModifiedAt: version),
              'archive' => service.archiveNote(
                  clientId: id, noteId: 'n', expectedModifiedAt: version),
              'delete' => service.deleteNote(
                  clientId: id, noteId: 'n', expectedModifiedAt: version),
              _ => service.updateNote(
                  clientId: id,
                  noteId: 'n',
                  content: 'Edited',
                  tags: destination,
                  expectedModifiedAt: version),
            };
            final context = 'mask=$mask operation=$operation';
            String? error;
            if (!permissions.contains(required)) {
              error = 'permission_denied';
            } else if (operation == 'daily-append-new' &&
                !permissions.contains(McpPermission.create)) {
              error = 'permission_denied';
            } else if (![
                  'list',
                  'search',
                  'create',
                  'tag-list',
                  'link',
                  'block',
                  'daily-create',
                  'daily-append-new'
                ].contains(operation) &&
                (!(operation == 'daily-append-existing'
                        ? accessible(['journal'])
                        : visible) ||
                    (operation == 'archived' &&
                        !permissions
                            .contains(McpPermission.includeArchived)))) {
              error = 'note_not_found';
            } else if (required.isWrite && !accessible(destination)) {
              error = 'permission_denied';
            }
            if (error != null) {
              await expectLater(
                  future,
                  throwsA(isA<McpOperationException>()
                      .having((e) => e.code, 'code', error)),
                  reason: context);
              expect(repository.notes, beforeNotes, reason: context);
              expect(prompts, beforePrompts, reason: context);
            } else {
              final result = await future;
              if (operation == 'list' || operation == 'search') {
                final rows = result['notes'] as List;
                expect(
                    rows.length,
                    visible
                        ? (operation == 'list' &&
                                permissions
                                    .contains(McpPermission.includeArchived)
                            ? 2
                            : 1)
                        : 0,
                    reason: context);
                if (operation == 'list' ||
                    !permissions.contains(McpPermission.readContent)) {
                  expect(result.toString(), isNot(contains('body-canary')),
                      reason: context);
                }
              }
              final expectedPrompts = required.isWrite &&
                      (policy == McpWritePolicy.askEveryTime ||
                          required == McpPermission.delete)
                  ? 1
                  : 0;
              expect(prompts - beforePrompts, expectedPrompts, reason: context);
              if (required.isWrite &&
                  operation != 'delete' &&
                  operation != 'create' &&
                  !permissions.contains(McpPermission.readContent)) {
                expect(result.toString(), isNot(contains('body-canary')),
                    reason: context);
              }
            }
            expect(approvals.pending, isEmpty, reason: context);
            checks++;
          }
        }
        expect(checks, 512 * 21);
      }, timeout: const Timeout(Duration(minutes: 10)));
    }
  }
}
