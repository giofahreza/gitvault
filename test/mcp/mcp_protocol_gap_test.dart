import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitvault/core/session/vault_session_controller.dart';
import 'package:gitvault/mcp/mcp_approval_controller.dart';
import 'package:gitvault/mcp/mcp_client_registry.dart';
import 'package:gitvault/mcp/mcp_models.dart';
import 'package:gitvault/mcp/mcp_server_factory.dart';
import 'package:gitvault/mcp/notes_mcp_service.dart';
import 'package:mcp_dart/mcp_dart.dart';

import 'test_support.dart';

class _LinkedTransport extends Transport {
  late _LinkedTransport peer;
  @override
  String? get sessionId => null;
  @override
  Future<void> start() async {}
  @override
  Future<void> send(JsonRpcMessage message, {int? relatedRequestId}) async {
    scheduleMicrotask(() => peer.onmessage?.call(message));
  }

  @override
  Future<void> close() async {
    onclose?.call();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late McpClientRegistry registry;
  late McpApprovalController approvals;
  late VaultSessionState session;
  late GitVaultMcpServerFactory factory;
  late MemoryNotesRepository repository;

  setUpAll(() async {
    directory = await initializeTestHive();
    silenceMcpLogs();
  });
  setUp(() async {
    await resetMcpBoxes();
    registry = McpClientRegistry();
    await registry.setEnabled(true);
    approvals = McpApprovalController();
    session = VaultSessionState(
        status: VaultSessionStatus.unlocked,
        changedAt: DateTime.now(),
        generation: 1);
    repository = MemoryNotesRepository([
      testNote(
          id: 'work',
          title: 'Work note',
          content: 'body-canary',
          tags: ['work']),
      testNote(
          id: 'private',
          title: 'Secret title',
          content: 'private-canary',
          tags: ['private']),
    ]);
    factory = GitVaultMcpServerFactory(
        registry: registry,
        version: 'test',
        notesService: NotesMcpService(
            notesRepository: repository,
            registry: registry,
            approvalController: approvals,
            readSession: () => session));
  });
  tearDown(() async {
    approvals.dispose();
    registry.dispose();
    await resetMcpBoxes();
  });
  tearDownAll(() => closeTestHive(directory));

  Future<({McpClient client, String id})> connect(
      {Set<McpPermission>? permissions,
      Set<String> allowedTags = const {},
      McpProtocol protocol = McpProtocol.stable}) async {
    final issued = await registry.createClient(
        displayName: 'Protocol client',
        transport: McpClientTransport.streamableHttp,
        permissions: permissions ?? McpPermission.values.toSet(),
        allowedTags: allowedTags,
        writePolicy: McpWritePolicy.allowWhileUnlocked);
    final server = factory.createForClient(issued.client.id);
    final left = _LinkedTransport(), right = _LinkedTransport();
    left.peer = right;
    right.peer = left;
    final client = McpClient(const Implementation(name: 'test', version: '1'),
        options: McpClientOptions(protocol: protocol));
    await server.connect(left);
    await client.connect(right);
    addTearDown(() async {
      await client.close();
      await server.close();
    });
    return (client: client, id: issued.client.id);
  }

  const exposed = {
    'list_notes',
    'list_note_tags',
    'resolve_note_link',
    'search_notes',
    'get_note',
    'get_note_outline',
    'list_backlinks',
    'resolve_block_reference',
    'create_note',
    'get_or_create_daily_note',
    'append_to_note',
    'append_to_daily_note',
    'update_note',
    'update_note_section',
    'archive_note',
    'delete_note',
  };

  test('MCP-GAP-019 exact exposed surface contains only permitted note tools',
      () async {
    final full = await connect();
    final tools = await full.client.listTools();
    expect(tools.tools.map((t) => t.name).toSet(), exposed);
    final limited = await connect(permissions: {McpPermission.readMetadata});
    expect((await limited.client.listTools()).tools.map((t) => t.name).toSet(),
        {'list_notes', 'list_note_tags', 'resolve_note_link'});
    for (final forbidden in [
      'get_password',
      'list_totp',
      'get_ssh_key',
      'get_github_token',
      'get_recovery_phrase',
      'link_device'
    ]) {
      await expectLater(
          full.client.callTool(CallToolRequest(name: forbidden, arguments: {})),
          throwsA(isA<McpError>().having((e) => e.code, 'code', -32602)));
    }
  });

  for (final protocol in McpProtocol.values) {
    test('MCP-GAP-001 $protocol exact maximum and one-over input boundaries',
        () async {
      final connected = await connect(protocol: protocol);
      approvals.addListener(() {
        final request = approvals.nextRequest;
        if (request != null)
          approvals.resolve(request.id, McpApprovalDecision.allowOnce);
      });
      const boundaries = <String, List<(String, int)>>{
        'list_notes': [('limit', 100)],
        'search_notes': [('query', 500), ('limit', 100)],
        'resolve_note_link': [('query', 500)],
        'get_note': [('note_id', 100)],
        'get_note_outline': [('note_id', 100)],
        'list_backlinks': [('note_id', 100)],
        'resolve_block_reference': [('block_id', 100)],
        'create_note': [
          ('title', 500),
          ('content', 262144),
          ('tags', 50),
          ('tag-length', 80),
          ('aliases', 50),
          ('alias-length', 200),
          ('checklist_items', 500),
          ('checklist-text', 2000)
        ],
        'get_or_create_daily_note': [('template', 262144)],
        'append_to_note': [('note_id', 100), ('text', 262144)],
        'append_to_daily_note': [('text', 262144)],
        'update_note': [
          ('note_id', 100),
          ('title', 500),
          ('content', 262144),
          ('tags', 50),
          ('tag-length', 80),
          ('aliases', 50),
          ('alias-length', 200),
          ('checklist_items', 500),
          ('checklist-text', 2000)
        ],
        'update_note_section': [
          ('note_id', 100),
          ('heading', 500),
          ('content', 262144)
        ],
        'archive_note': [('note_id', 100)],
        'delete_note': [('note_id', 100)],
      };
      var checks = 0;
      for (final tool in boundaries.entries) {
        for (final boundary in tool.value) {
          for (final over in [false, true]) {
            final field = boundary.$1;
            final count = boundary.$2 + (over ? 1 : 0);
            final noteId = field == 'note_id' ? 'n' * count : 'boundary';
            final heading = field == 'heading' ? 'h' * count : 'Heading';
            repository.notes.clear();
            final note = testNote(
                id: noteId,
                title: 'Boundary',
                content: tool.key == 'update_note_section'
                    ? '# $heading\nBody'
                    : '');
            repository.notes[noteId] = note;
            final arguments = <String, dynamic>{
              if (['search_notes', 'resolve_note_link'].contains(tool.key))
                'query': 'Boundary',
              if ([
                'get_note',
                'get_note_outline',
                'list_backlinks',
                'append_to_note',
                'update_note',
                'update_note_section',
                'archive_note',
                'delete_note'
              ].contains(tool.key))
                'note_id': noteId,
              if ([
                'append_to_note',
                'update_note',
                'update_note_section',
                'archive_note',
                'delete_note'
              ].contains(tool.key))
                'expected_modified_at':
                    note.modifiedAt.toUtc().toIso8601String(),
              if (tool.key == 'create_note') ...{
                'title': 'Created',
                'content': ''
              },
              if (tool.key == 'update_note') 'content': '',
              if (tool.key == 'update_note_section') ...{
                'heading': heading,
                'content': 'Replacement'
              },
              if (['append_to_note', 'append_to_daily_note'].contains(tool.key))
                'text': 'Append',
              if (['get_or_create_daily_note', 'append_to_daily_note']
                  .contains(tool.key))
                'date': '2026-11-23',
              if (tool.key == 'resolve_block_reference') 'block_id': 'block1',
            };
            switch (field) {
              case 'limit':
                arguments[field] = count;
              case 'tags' || 'aliases':
                arguments[field] = List.generate(count, (i) => 'value-$i');
              case 'tag-length':
                arguments['tags'] = ['t' * count];
              case 'alias-length':
                arguments['aliases'] = ['a' * count];
              case 'checklist_items':
                arguments[field] =
                    List.generate(count, (_) => {'text': 'Task'});
              case 'checklist-text':
                arguments['checklist_items'] = [
                  {'text': 't' * count}
                ];
              default:
                arguments[field] = field == 'note_id'
                    ? noteId
                    : field == 'heading'
                        ? heading
                        : 'x' * count;
            }
            final before = Map.of(repository.notes);
            CallToolResult? result;
            McpError? failure;
            try {
              result = await connected.client.callTool(
                  CallToolRequest(name: tool.key, arguments: arguments));
            } on McpError catch (error) {
              failure = error;
            }
            final aggregateOverflow =
                tool.key == 'update_note_section' && field == 'content';
            final rejected = failure != null || result?.isError == true;
            expect(rejected, over || aggregateOverflow,
                reason:
                    '${tool.key} $field ${over ? "one-over" : "exact"}: ${result?.structuredContent ?? failure}');
            if (rejected) expect(repository.notes, before);
            expect(approvals.pending, isEmpty);
            checks++;
          }
        }
      }
      expect(checks, 68);
    });

    test('MCP-GAP-001 $protocol bounds imported metadata and search previews',
        () async {
      final connected = await connect(protocol: protocol);
      repository.notes.clear();
      repository.notes['imported'] = testNote(
              id: 'imported',
              title: 't' * 501,
              content: 'x' * 262145,
              tags: List.generate(51, (i) => '$i${'t' * 81}'))
          .copyWith(aliases: List.generate(51, (i) => '$i${'a' * 201}'));
      final list = await connected.client
          .callTool(const CallToolRequest(name: 'list_notes', arguments: {}));
      final metadata = (list.structuredContent!['notes'] as List).single as Map;
      expect(metadata['title'], hasLength(500));
      expect(metadata['tags'], hasLength(50));
      expect(metadata['aliases'], hasLength(50));
      expect(
          (metadata['tags'] as List).every((t) => (t as String).length <= 80),
          true);
      expect(
          (metadata['aliases'] as List)
              .every((a) => (a as String).length <= 200),
          true);
      expect(metadata['metadata_truncated'], true);
      expect(metadata.containsKey('content'), false);
      final search = await connected.client.callTool(const CallToolRequest(
          name: 'search_notes', arguments: {'query': 'x'}));
      expect(
          ((search.structuredContent!['notes'] as List).single
              as Map)['content'],
          hasLength(503));
      repository.notes['exact'] =
          testNote(id: 'exact', title: 'Exact', content: 'x' * 262144);
      final exact = await connected.client.callTool(const CallToolRequest(
          name: 'get_note', arguments: {'note_id': 'exact'}));
      expect(exact.isError, false);
      expect(exact.structuredContent!['note']['content'], hasLength(262144));
      final resource = await connected.client.readResource(
          const ReadResourceRequest(uri: 'gitvault://notes/exact'));
      expect(resource.contents, hasLength(1));
    });

    test(
        'MCP-GAP-001 $protocol bounds all collection outputs and large resources',
        () async {
      final connected = await connect(protocol: protocol);
      repository.notes.clear();
      repository.notes['target'] = testNote(
          id: 'target',
          title: 'Target',
          content:
              List.generate(105, (i) => '# H$i\nBody ^block-$i').join('\n'));
      for (var i = 0; i < 105; i++) {
        repository.notes['n$i'] = testNote(
            id: 'n$i',
            title: 'Duplicate',
            tags: ['tag-$i'],
            content: '[[Target]]\nBody ^shared');
      }
      Future<Map<String, dynamic>> call(
          String tool, Map<String, dynamic> arguments) async {
        final result = await connected.client
            .callTool(CallToolRequest(name: tool, arguments: arguments));
        expect(result.isError, false);
        return result.structuredContent!;
      }

      for (final operation in [
        ('list_notes', <String, dynamic>{'limit': 100}, 'notes'),
        (
          'search_notes',
          <String, dynamic>{'query': 'Body', 'limit': 100},
          'notes'
        ),
        ('list_note_tags', <String, dynamic>{}, 'tags'),
        (
          'resolve_note_link',
          <String, dynamic>{'query': 'Duplicate'},
          'matches'
        ),
        ('list_backlinks', <String, dynamic>{'note_id': 'target'}, 'backlinks'),
        (
          'resolve_block_reference',
          <String, dynamic>{'block_id': 'shared'},
          'matches'
        ),
        (
          'get_note_outline',
          <String, dynamic>{'note_id': 'target'},
          'headings'
        ),
        ('get_note_outline', <String, dynamic>{'note_id': 'target'}, 'blocks'),
      ]) {
        final output = await call(operation.$1, operation.$2);
        expect(output[operation.$3] as List, hasLength(100),
            reason: operation.$1);
      }
      repository.notes['large'] = testNote(
          id: 'large', title: 'Large', content: 'x' * (256 * 1024 + 1));
      final tooLarge = await connected.client.callTool(const CallToolRequest(
          name: 'get_note', arguments: {'note_id': 'large'}));
      expect(tooLarge.isError, true);
      expect(tooLarge.structuredContent!['error']['code'], 'invalid_input');
      await expectLater(
          connected.client.readResource(
              const ReadResourceRequest(uri: 'gitvault://notes/large')),
          throwsA(isA<McpError>()));
    });
    for (final tool in exposed) {
      test(
          'MCP-GAP-001 $protocol invalid arguments to $tool fail without mutation',
          () async {
        final connected = await connect(protocol: protocol);
        final original = Map.of(repository.notes);
        CallToolResult? response;
        McpError? error;
        try {
          response = await connected.client.callTool(CallToolRequest(
              name: tool, arguments: {'unexpected_argument': true}));
        } on McpError catch (caught) {
          error = caught;
        }
        expect(error != null || response?.isError == true, true);
        expect(repository.notes, original);
        expect(approvals.pending, isEmpty);
      });
    }
  }

  test('MCP-GAP-007 resources expose note template and enforce live scope/lock',
      () async {
    final connected = await connect(allowedTags: {'work'});
    expect((await connected.client.listResources()).resources, isEmpty);
    final templates = await connected.client.listResourceTemplates();
    expect(templates.resourceTemplates.map((t) => t.uriTemplate),
        ['gitvault://notes/{uuid}']);
    final result = await connected.client
        .readResource(const ReadResourceRequest(uri: 'gitvault://notes/work'));
    expect((result.contents.single as TextResourceContents).text,
        contains('body-canary'));
    await expectLater(
        connected.client.readResource(
            const ReadResourceRequest(uri: 'gitvault://notes/private')),
        throwsA(isA<McpError>()));
    session = VaultSessionState(
        status: VaultSessionStatus.locked,
        changedAt: DateTime.now(),
        generation: 2);
    await expectLater(
        connected.client.readResource(
            const ReadResourceRequest(uri: 'gitvault://notes/work')),
        throwsA(isA<McpError>()));
    session = VaultSessionState(
        status: VaultSessionStatus.unlocked,
        changedAt: DateTime.now(),
        generation: 3);
    await registry.revokeClient(connected.id);
    await expectLater(
        connected.client.readResource(
            const ReadResourceRequest(uri: 'gitvault://notes/work')),
        throwsA(isA<McpError>()));
  });

  test('MCP-GAP-007 metadata-only client has no content resource template',
      () async {
    final connected = await connect(permissions: {McpPermission.readMetadata});
    await expectLater(connected.client.listResourceTemplates(),
        throwsA(isA<McpError>().having((e) => e.code, 'code', -32601)));
    await expectLater(
        connected.client.readResource(
            const ReadResourceRequest(uri: 'gitvault://notes/work')),
        throwsA(isA<McpError>()));
  });

  test(
      'MCP-GAP-014 independent protocol sessions keep permissions and revocation isolated',
      () async {
    final work = await connect(allowedTags: {'work'});
    final private = await connect(allowedTags: {'private'});
    final results = await Future.wait([
      work.client
          .callTool(const CallToolRequest(name: 'list_notes', arguments: {})),
      private.client
          .callTool(const CallToolRequest(name: 'list_notes', arguments: {})),
    ]);
    expect((results[0].structuredContent!['notes'] as List).single['uuid'],
        'work');
    expect((results[1].structuredContent!['notes'] as List).single['uuid'],
        'private');
    await registry.revokeClient(work.id);
    expect(
        (await work.client.callTool(
                const CallToolRequest(name: 'list_notes', arguments: {})))
            .isError,
        true);
    final survivor = await private.client
        .callTool(const CallToolRequest(name: 'list_notes', arguments: {}));
    expect(survivor.isError, false);
    expect((survivor.structuredContent!['notes'] as List).single['uuid'],
        'private');
  });
}
