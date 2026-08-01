import 'dart:convert';

import 'package:mcp_dart/mcp_dart.dart';

import 'mcp_client_registry.dart';
import 'mcp_models.dart';
import 'notes_mcp_service.dart';

class GitVaultMcpServerFactory {
  final McpClientRegistry registry;
  final NotesMcpService notesService;
  final String version;

  const GitVaultMcpServerFactory({
    required this.registry,
    required this.notesService,
    required this.version,
  });

  McpServer createForClient(String clientId) {
    final client = registry.getClient(clientId);
    if (client == null || !client.isActive) {
      throw const McpOperationException(
        'client_not_paired',
        'The AI app is not connected to GitVault.',
      );
    }

    final server = McpServer(
      Implementation(name: 'gitvault-notes', version: version),
      options: const McpServerOptions(
        protocol: McpProtocol.stable,
        capabilities: ServerCapabilities(
          tools: ServerCapabilitiesTools(),
          resources: ServerCapabilitiesResources(),
        ),
      ),
    );

    _registerTools(server, client);
    _registerResources(server, client);
    return server;
  }

  void _registerTools(
    McpServer server,
    McpClientRegistration client,
  ) {
    if (client.permissions.contains(McpPermission.readMetadata)) {
      server.registerTool(
        'list_notes',
        description:
            'List GitVault note metadata using bounded pagination. Note bodies are not returned.',
        inputSchema: _paginationSchema(),
        annotations: const ToolAnnotations(
          readOnlyHint: true,
          destructiveHint: false,
          idempotentHint: true,
          openWorldHint: false,
        ),
        callback: (args, extra) => _result(
          () => notesService.listNotes(
            clientId: client.id,
            offset: _integer(args, 'offset', 0),
            limit: _integer(args, 'limit', 25),
          ),
        ),
      );

      server.registerTool(
        'list_note_tags',
        description: 'List tags from notes visible to this AI app.',
        inputSchema: JsonSchema.object(
          properties: const {},
          additionalProperties: false,
        ),
        annotations: const ToolAnnotations(
          readOnlyHint: true,
          destructiveHint: false,
          idempotentHint: true,
          openWorldHint: false,
        ),
        callback: (args, extra) => _result(
          () => notesService.listNoteTags(clientId: client.id),
        ),
      );

      server.registerTool(
        'resolve_note_link',
        description:
            'Resolve a GitVault note title, alias, wiki-link target, or UUID without reading note bodies.',
        inputSchema: JsonSchema.object(
          properties: {
            'query': JsonSchema.string(maxLength: 500),
          },
          required: const ['query'],
          additionalProperties: false,
        ),
        annotations: const ToolAnnotations(
          readOnlyHint: true,
          destructiveHint: false,
          idempotentHint: true,
          openWorldHint: false,
        ),
        callback: (args, extra) => _result(
          () => notesService.resolveNoteLink(
            clientId: client.id,
            query: _requiredString(args, 'query'),
          ),
        ),
      );
    }

    if (client.permissions.contains(McpPermission.search)) {
      server.registerTool(
        'search_notes',
        description: client.permissions.contains(McpPermission.readContent)
            ? 'Search GitVault notes by title, content, or tag. Results are scoped and paginated.'
            : 'Search GitVault notes by title or tag. Results are scoped and paginated; note bodies are not searched or returned.',
        inputSchema: JsonSchema.object(
          properties: {
            'query': JsonSchema.string(maxLength: 500),
            'offset': JsonSchema.integer(minimum: 0, defaultValue: 0),
            'limit': JsonSchema.integer(
              minimum: 1,
              maximum: 100,
              defaultValue: 25,
            ),
          },
          required: const ['query'],
          additionalProperties: false,
        ),
        annotations: const ToolAnnotations(
          readOnlyHint: true,
          destructiveHint: false,
          idempotentHint: true,
          openWorldHint: false,
        ),
        callback: (args, extra) => _result(
          () => notesService.searchNotes(
            clientId: client.id,
            query: _requiredString(args, 'query'),
            offset: _integer(args, 'offset', 0),
            limit: _integer(args, 'limit', 25),
          ),
        ),
      );
    }

    if (client.permissions.contains(McpPermission.readContent)) {
      server.registerTool(
        'get_note',
        description:
            'Read one GitVault note. Use the returned modified_at value for later writes.',
        inputSchema: _noteIdSchema(),
        annotations: const ToolAnnotations(
          readOnlyHint: true,
          destructiveHint: false,
          idempotentHint: true,
          openWorldHint: false,
        ),
        callback: (args, extra) => _result(
          () => notesService.getNote(
            clientId: client.id,
            noteId: _requiredString(args, 'note_id'),
          ),
        ),
      );

      server.registerTool(
        'get_note_outline',
        description:
            'Return Markdown headings, block anchors, and task counts for one note.',
        inputSchema: _noteIdSchema(),
        annotations: const ToolAnnotations(
          readOnlyHint: true,
          destructiveHint: false,
          idempotentHint: true,
          openWorldHint: false,
        ),
        callback: (args, extra) => _result(
          () => notesService.getNoteOutline(
            clientId: client.id,
            noteId: _requiredString(args, 'note_id'),
          ),
        ),
      );

      server.registerTool(
        'list_backlinks',
        description:
            'List scoped notes that link to or mention the requested note.',
        inputSchema: JsonSchema.object(
          properties: {
            'note_id': JsonSchema.string(maxLength: 100),
            'include_unlinked_mentions': JsonSchema.boolean(defaultValue: true),
          },
          required: const ['note_id'],
          additionalProperties: false,
        ),
        annotations: const ToolAnnotations(
          readOnlyHint: true,
          destructiveHint: false,
          idempotentHint: true,
          openWorldHint: false,
        ),
        callback: (args, extra) => _result(
          () => notesService.listBacklinks(
            clientId: client.id,
            noteId: _requiredString(args, 'note_id'),
            includeUnlinkedMentions:
                _boolean(args, 'include_unlinked_mentions', true),
          ),
        ),
      );

      server.registerTool(
        'resolve_block_reference',
        description:
            'Resolve a scoped Markdown block anchor such as ^decision-1.',
        inputSchema: JsonSchema.object(
          properties: {
            'block_id': JsonSchema.string(maxLength: 100),
          },
          required: const ['block_id'],
          additionalProperties: false,
        ),
        annotations: const ToolAnnotations(
          readOnlyHint: true,
          destructiveHint: false,
          idempotentHint: true,
          openWorldHint: false,
        ),
        callback: (args, extra) => _result(
          () => notesService.resolveBlockReference(
            clientId: client.id,
            blockId: _requiredString(args, 'block_id'),
          ),
        ),
      );
    }

    if (client.permissions.contains(McpPermission.create)) {
      server.registerTool(
        'create_note',
        description:
            'Create an encrypted GitVault note. Desktop approval may be required.',
        inputSchema: JsonSchema.object(
          properties: {
            'title': JsonSchema.string(maxLength: 500),
            'content': JsonSchema.string(maxLength: 256 * 1024),
            'tags': _tagsSchema(),
            'aliases': _aliasesSchema(),
            'color': _colorSchema(),
            'pinned': JsonSchema.boolean(defaultValue: false),
            'checklist': JsonSchema.boolean(defaultValue: false),
            'checklist_items': _checklistItemsSchema(),
          },
          required: const ['title', 'content'],
          additionalProperties: false,
        ),
        annotations: const ToolAnnotations(
          readOnlyHint: false,
          destructiveHint: false,
          idempotentHint: false,
          openWorldHint: false,
        ),
        callback: (args, extra) => _result(
          () => notesService.createNote(
            clientId: client.id,
            title: _requiredString(args, 'title'),
            content: _requiredString(args, 'content'),
            tags: _strings(args, 'tags'),
            aliases: _strings(args, 'aliases'),
            color: _string(args, 'color') ?? 'white',
            pinned: _boolean(args, 'pinned', false),
            checklist: _boolean(args, 'checklist', false),
            checklistItems: _objects(args, 'checklist_items'),
          ),
        ),
      );

      server.registerTool(
        'get_or_create_daily_note',
        description:
            'Return the journal note for a date, creating encrypted Markdown from an optional template when absent.',
        inputSchema: JsonSchema.object(
          properties: {
            'date': _dateSchema(),
            'template': JsonSchema.string(maxLength: 256 * 1024),
          },
          required: const ['date'],
          additionalProperties: false,
        ),
        annotations: const ToolAnnotations(
          readOnlyHint: false,
          destructiveHint: false,
          idempotentHint: true,
          openWorldHint: false,
        ),
        callback: (args, extra) => _result(
          () => notesService.getOrCreateDailyNote(
            clientId: client.id,
            date: _requiredString(args, 'date'),
            template: _string(args, 'template'),
          ),
        ),
      );
    }

    if (client.permissions.contains(McpPermission.append)) {
      server.registerTool(
        'append_to_note',
        description:
            'Append text to a note if it has not changed since expected_modified_at.',
        inputSchema: JsonSchema.object(
          properties: {
            'note_id': JsonSchema.string(maxLength: 100),
            'text': JsonSchema.string(maxLength: 256 * 1024),
            'expected_modified_at': _timestampSchema(),
            'add_newline': JsonSchema.boolean(defaultValue: true),
          },
          required: const ['note_id', 'text', 'expected_modified_at'],
          additionalProperties: false,
        ),
        annotations: const ToolAnnotations(
          readOnlyHint: false,
          destructiveHint: false,
          idempotentHint: false,
          openWorldHint: false,
        ),
        callback: (args, extra) => _result(
          () => notesService.appendToNote(
            clientId: client.id,
            noteId: _requiredString(args, 'note_id'),
            text: _requiredString(args, 'text'),
            expectedModifiedAt: _requiredString(args, 'expected_modified_at'),
            addNewline: _boolean(args, 'add_newline', true),
          ),
        ),
      );

      server.registerTool(
        'append_to_daily_note',
        description:
            'Append Markdown to a dated journal note. Existing notes require expected_modified_at; creation also requires Create permission.',
        inputSchema: JsonSchema.object(
          properties: {
            'date': _dateSchema(),
            'text': JsonSchema.string(maxLength: 256 * 1024),
            'expected_modified_at': _timestampSchema(),
          },
          required: const ['date', 'text'],
          additionalProperties: false,
        ),
        annotations: const ToolAnnotations(
          readOnlyHint: false,
          destructiveHint: false,
          idempotentHint: false,
          openWorldHint: false,
        ),
        callback: (args, extra) => _result(
          () => notesService.appendToDailyNote(
            clientId: client.id,
            date: _requiredString(args, 'date'),
            text: _requiredString(args, 'text'),
            expectedModifiedAt: _string(args, 'expected_modified_at'),
          ),
        ),
      );
    }

    if (client.permissions.contains(McpPermission.edit)) {
      server.registerTool(
        'update_note',
        description:
            'Patch explicit note fields if the note has not changed since expected_modified_at.',
        inputSchema: JsonSchema.object(
          properties: {
            'note_id': JsonSchema.string(maxLength: 100),
            'expected_modified_at': _timestampSchema(),
            'title': JsonSchema.string(maxLength: 500),
            'content': JsonSchema.string(maxLength: 256 * 1024),
            'tags': _tagsSchema(),
            'aliases': _aliasesSchema(),
            'color': _colorSchema(),
            'pinned': JsonSchema.boolean(),
            'checklist': JsonSchema.boolean(),
            'checklist_items': _checklistItemsSchema(),
          },
          required: const ['note_id', 'expected_modified_at'],
          additionalProperties: false,
        ),
        annotations: const ToolAnnotations(
          readOnlyHint: false,
          destructiveHint: true,
          idempotentHint: true,
          openWorldHint: false,
        ),
        callback: (args, extra) => _result(
          () => notesService.updateNote(
            clientId: client.id,
            noteId: _requiredString(args, 'note_id'),
            expectedModifiedAt: _requiredString(args, 'expected_modified_at'),
            title: _string(args, 'title'),
            content: _string(args, 'content'),
            tags: args.containsKey('tags') ? _strings(args, 'tags') : null,
            aliases:
                args.containsKey('aliases') ? _strings(args, 'aliases') : null,
            color: _string(args, 'color'),
            pinned: args['pinned'] as bool?,
            checklist: args['checklist'] as bool?,
            checklistItems: args.containsKey('checklist_items')
                ? _objects(args, 'checklist_items')
                : null,
          ),
        ),
      );

      server.registerTool(
        'update_note_section',
        description:
            'Replace one Markdown heading section using its outline title or anchor and optimistic concurrency.',
        inputSchema: JsonSchema.object(
          properties: {
            'note_id': JsonSchema.string(maxLength: 100),
            'expected_modified_at': _timestampSchema(),
            'heading': JsonSchema.string(maxLength: 500),
            'content': JsonSchema.string(maxLength: 256 * 1024),
          },
          required: const [
            'note_id',
            'expected_modified_at',
            'heading',
            'content',
          ],
          additionalProperties: false,
        ),
        annotations: const ToolAnnotations(
          readOnlyHint: false,
          destructiveHint: true,
          idempotentHint: true,
          openWorldHint: false,
        ),
        callback: (args, extra) => _result(
          () => notesService.updateNoteSection(
            clientId: client.id,
            noteId: _requiredString(args, 'note_id'),
            expectedModifiedAt: _requiredString(args, 'expected_modified_at'),
            heading: _requiredString(args, 'heading'),
            content: _requiredString(args, 'content'),
          ),
        ),
      );
    }

    if (client.permissions.contains(McpPermission.archive)) {
      server.registerTool(
        'archive_note',
        description:
            'Archive a note if it has not changed since expected_modified_at.',
        inputSchema: _versionedNoteSchema(),
        annotations: const ToolAnnotations(
          readOnlyHint: false,
          destructiveHint: false,
          idempotentHint: true,
          openWorldHint: false,
        ),
        callback: (args, extra) => _result(
          () => notesService.archiveNote(
            clientId: client.id,
            noteId: _requiredString(args, 'note_id'),
            expectedModifiedAt: _requiredString(args, 'expected_modified_at'),
          ),
        ),
      );
    }

    if (client.permissions.contains(McpPermission.delete)) {
      server.registerTool(
        'delete_note',
        description:
            'Permanently delete a note. GitVault Desktop always requires explicit approval.',
        inputSchema: _versionedNoteSchema(),
        annotations: const ToolAnnotations(
          readOnlyHint: false,
          destructiveHint: true,
          idempotentHint: true,
          openWorldHint: false,
        ),
        callback: (args, extra) => _result(
          () => notesService.deleteNote(
            clientId: client.id,
            noteId: _requiredString(args, 'note_id'),
            expectedModifiedAt: _requiredString(args, 'expected_modified_at'),
          ),
        ),
      );
    }
  }

  void _registerResources(
    McpServer server,
    McpClientRegistration client,
  ) {
    if (!client.permissions.contains(McpPermission.readContent)) return;
    server.registerResourceTemplate(
      'GitVault Note',
      ResourceTemplateRegistration(
        'gitvault://notes/{uuid}',
        listCallback: null,
      ),
      (
        description: 'Read one note visible to this AI app.',
        mimeType: 'application/json'
      ),
      (uri, variables, extra) async {
        final noteId = variables['uuid'];
        if (noteId is! String || noteId.isEmpty) {
          throw const McpOperationException(
            'invalid_input',
            'A note UUID is required.',
          );
        }
        final result = await notesService.getNote(
          clientId: client.id,
          noteId: noteId,
        );
        return ReadResourceResult(
          contents: [
            TextResourceContents(
              uri: uri.toString(),
              mimeType: 'application/json',
              text: jsonEncode(result),
            ),
          ],
        );
      },
    );
  }

  Future<CallToolResult> _result(
    Future<Map<String, dynamic>> Function() operation,
  ) async {
    try {
      final result = await operation();
      return CallToolResult.fromStructuredContent(result);
    } on McpOperationException catch (error) {
      final payload = {'error': error.toJson()};
      return CallToolResult(
        isError: true,
        structuredContent: payload,
        content: [TextContent(text: jsonEncode(payload))],
      );
    } catch (_) {
      const error = McpOperationException(
        'internal_error',
        'GitVault could not complete the MCP request.',
      );
      final payload = {'error': error.toJson()};
      return CallToolResult(
        isError: true,
        structuredContent: payload,
        content: [TextContent(text: jsonEncode(payload))],
      );
    }
  }

  JsonObject _paginationSchema() => JsonSchema.object(
        properties: {
          'offset': JsonSchema.integer(minimum: 0, defaultValue: 0),
          'limit': JsonSchema.integer(
            minimum: 1,
            maximum: 100,
            defaultValue: 25,
          ),
        },
        additionalProperties: false,
      );

  JsonObject _noteIdSchema() => JsonSchema.object(
        properties: {
          'note_id': JsonSchema.string(maxLength: 100),
        },
        required: const ['note_id'],
        additionalProperties: false,
      );

  JsonObject _versionedNoteSchema() => JsonSchema.object(
        properties: {
          'note_id': JsonSchema.string(maxLength: 100),
          'expected_modified_at': _timestampSchema(),
        },
        required: const ['note_id', 'expected_modified_at'],
        additionalProperties: false,
      );

  JsonString _timestampSchema() => JsonSchema.string(
        format: 'date-time',
        description: 'The exact modified_at timestamp from the latest read.',
      );

  JsonArray _tagsSchema() => JsonSchema.array(
        items: JsonSchema.string(maxLength: 80),
        maxItems: 50,
        uniqueItems: true,
      );

  JsonArray _aliasesSchema() => JsonSchema.array(
        items: JsonSchema.string(maxLength: 200),
        maxItems: 50,
        uniqueItems: true,
      );

  JsonString _dateSchema() => JsonSchema.string(
        format: 'date',
        description: 'A calendar date in YYYY-MM-DD format.',
      );

  JsonString _colorSchema() => JsonSchema.string(
        enumValues: const [
          'white',
          'red',
          'orange',
          'yellow',
          'green',
          'teal',
          'blue',
          'purple',
          'pink',
          'brown',
          'gray',
        ],
        defaultValue: 'white',
      );

  JsonArray _checklistItemsSchema() => JsonSchema.array(
        maxItems: 500,
        items: JsonSchema.object(
          properties: {
            'text': JsonSchema.string(maxLength: 2000),
            'is_checked': JsonSchema.boolean(defaultValue: false),
          },
          required: const ['text'],
          additionalProperties: false,
        ),
      );

  String _requiredString(Map<String, dynamic> args, String key) {
    final value = args[key];
    if (value is! String) {
      throw McpOperationException(
        'invalid_input',
        '$key must be a string.',
      );
    }
    return value;
  }

  String? _string(Map<String, dynamic> args, String key) {
    final value = args[key];
    if (value == null) return null;
    if (value is! String) {
      throw McpOperationException(
        'invalid_input',
        '$key must be a string.',
      );
    }
    return value;
  }

  int _integer(Map<String, dynamic> args, String key, int fallback) {
    final value = args[key];
    if (value == null) return fallback;
    if (value is! int) {
      throw McpOperationException(
        'invalid_input',
        '$key must be an integer.',
      );
    }
    return value;
  }

  bool _boolean(Map<String, dynamic> args, String key, bool fallback) {
    final value = args[key];
    if (value == null) return fallback;
    if (value is! bool) {
      throw McpOperationException(
        'invalid_input',
        '$key must be a boolean.',
      );
    }
    return value;
  }

  List<String> _strings(Map<String, dynamic> args, String key) {
    final value = args[key];
    if (value == null) return const [];
    if (value is! List || value.any((item) => item is! String)) {
      throw McpOperationException(
        'invalid_input',
        '$key must be an array of strings.',
      );
    }
    return value.cast<String>();
  }

  List<Map<String, dynamic>> _objects(
    Map<String, dynamic> args,
    String key,
  ) {
    final value = args[key];
    if (value == null) return const [];
    if (value is! List || value.any((item) => item is! Map)) {
      throw McpOperationException(
        'invalid_input',
        '$key must be an array of objects.',
      );
    }
    return value.map((item) => Map<String, dynamic>.from(item as Map)).toList();
  }
}
