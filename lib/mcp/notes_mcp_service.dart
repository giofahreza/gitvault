import 'dart:async';

import 'package:uuid/uuid.dart';

import '../core/notes/knowledge_index.dart';
import '../core/notes/knowledge_parser.dart';
import '../core/notes/note_templates.dart';
import '../core/services/foreground_sync_service.dart';
import '../core/session/vault_session_controller.dart';
import '../data/models/note.dart';
import '../data/repositories/notes_repository.dart';
import 'mcp_approval_controller.dart';
import 'mcp_client_registry.dart';
import 'mcp_models.dart';

typedef VaultSessionReader = VaultSessionState Function();
typedef McpMutationCallback = void Function();

const _vaultLockedError = McpOperationException(
  'vault_locked',
  'Unlock GitVault Desktop to use notes.',
);

bool _sameSet<T>(Set<T> left, Set<T> right) =>
    left.length == right.length && left.every(right.contains);

class NotesMcpService {
  static const int maximumPageSize = 100;
  static const int maximumTitleLength = 500;
  static const int maximumContentLength = 256 * 1024;
  static const int maximumQueryLength = 500;
  static const int maximumTagCount = 50;

  final NotesRepository _notesRepository;
  final McpClientRegistry _registry;
  final McpApprovalController _approvalController;
  final VaultSessionReader _readSession;
  final McpMutationCallback? _onMutation;
  final Uuid _uuid = const Uuid();
  final KnowledgeNoteParser _knowledgeParser = const KnowledgeNoteParser();

  NotesMcpService({
    required NotesRepository notesRepository,
    required McpClientRegistry registry,
    required McpApprovalController approvalController,
    required VaultSessionReader readSession,
    McpMutationCallback? onMutation,
  })  : _notesRepository = notesRepository,
        _registry = registry,
        _approvalController = approvalController,
        _readSession = readSession,
        _onMutation = onMutation;

  Future<Map<String, dynamic>> listNotes({
    required String clientId,
    int offset = 0,
    int limit = 25,
  }) {
    return _execute(
      clientId: clientId,
      action: 'list_notes',
      permission: McpPermission.readMetadata,
      operation: (client, _) async {
        final pagination = _pagination(offset, limit);
        await _notesRepository.initialize();
        final notes = await _visibleNotes(client);
        final page = notes
            .skip(pagination.offset)
            .take(pagination.limit)
            .map((note) => _noteJson(note, includeContent: false))
            .toList();
        return {
          'notes': page,
          'offset': pagination.offset,
          'limit': pagination.limit,
          'total': notes.length,
          'has_more': pagination.offset + page.length < notes.length,
        };
      },
    );
  }

  Future<Map<String, dynamic>> searchNotes({
    required String clientId,
    required String query,
    int offset = 0,
    int limit = 25,
  }) {
    return _execute(
      clientId: clientId,
      action: 'search_notes',
      permission: McpPermission.search,
      operation: (client, _) async {
        final normalizedQuery = query.trim();
        if (normalizedQuery.length > maximumQueryLength) {
          throw const McpOperationException(
            'invalid_input',
            'Search query is too long.',
          );
        }
        final pagination = _pagination(offset, limit);
        await _notesRepository.initialize();
        final notes = await _visibleNotes(client);
        final queryLower = normalizedQuery.toLowerCase();
        final canReadContent =
            client.permissions.contains(McpPermission.readContent);
        final visible = queryLower.isEmpty
            ? notes
            : notes.where((note) {
                return note.title.toLowerCase().contains(queryLower) ||
                    (canReadContent &&
                        note.markdownContent
                            .toLowerCase()
                            .contains(queryLower)) ||
                    note.tags.any(
                      (tag) => tag.toLowerCase().contains(queryLower),
                    );
              }).toList();
        final page = visible
            .skip(pagination.offset)
            .take(pagination.limit)
            .map(
              (note) => _noteJson(
                note,
                includeContent: canReadContent,
                contentAsSnippet: canReadContent,
              ),
            )
            .toList();
        return {
          'notes': page,
          'offset': pagination.offset,
          'limit': pagination.limit,
          'total': visible.length,
          'has_more': pagination.offset + page.length < visible.length,
        };
      },
    );
  }

  Future<Map<String, dynamic>> getNote({
    required String clientId,
    required String noteId,
  }) {
    return _execute(
      clientId: clientId,
      action: 'get_note',
      noteId: noteId,
      permission: McpPermission.readContent,
      operation: (client, _) async {
        final note = await _requireVisibleNote(client, noteId);
        return {'note': _noteJson(note, includeContent: true)};
      },
    );
  }

  Future<Map<String, dynamic>> listNoteTags({
    required String clientId,
  }) {
    return _execute(
      clientId: clientId,
      action: 'list_note_tags',
      permission: McpPermission.readMetadata,
      operation: (client, _) async {
        await _notesRepository.initialize();
        final notes = await _visibleNotes(client);
        final tags = <String>{};
        for (final note in notes) {
          tags.addAll(note.tags);
        }
        final sorted = tags.toList()..sort();
        return {'tags': sorted};
      },
    );
  }

  Future<Map<String, dynamic>> createNote({
    required String clientId,
    required String title,
    required String content,
    List<String> tags = const [],
    List<String> aliases = const [],
    String color = 'white',
    bool pinned = false,
    bool checklist = false,
    List<Map<String, dynamic>> checklistItems = const [],
  }) {
    return _execute(
      clientId: clientId,
      action: 'create_note',
      permission: McpPermission.create,
      operation: (client, sessionGeneration) async {
        final validatedTitle = _validateTitle(title);
        final validatedContent = _validateContent(content);
        final validatedTags = _validateTags(tags);
        final validatedAliases = _validateAliases(aliases);
        _ensureWritableTags(client, validatedTags);
        final noteColor = _parseColor(color);
        final items = _parseChecklistItems(checklistItems);
        final markdownContent = _validateContent(
          checklist ? _checklistMarkdown(items) : validatedContent,
        );

        await _notesRepository.initialize();
        await _approveWrite(
          client: client,
          permission: McpPermission.create,
          action: 'create_note',
          summary: 'Create a new note named "$validatedTitle"',
          after: markdownContent,
          sessionGeneration: sessionGeneration,
        );
        _ensureOperationAccess(client, sessionGeneration);
        final note = await _notesRepository.createNote(
          title: validatedTitle,
          content: markdownContent,
          formatVersion: 2,
          tags: validatedTags,
          aliases: validatedAliases,
          color: noteColor,
          isPinned: pinned,
          isChecklist: false,
          checklistItems: const [],
        );
        _afterMutation('MCP note created');
        return {'note': _noteJson(note, includeContent: true)};
      },
      approvalHandledByOperation: true,
    );
  }

  Future<Map<String, dynamic>> appendToNote({
    required String clientId,
    required String noteId,
    required String text,
    required String expectedModifiedAt,
    bool addNewline = true,
  }) {
    return _execute(
      clientId: clientId,
      action: 'append_to_note',
      noteId: noteId,
      permission: McpPermission.append,
      operation: (client, sessionGeneration) async {
        final note = await _requireVisibleNote(client, noteId);
        _ensureExpectedVersion(note, expectedModifiedAt);
        final validatedText = _validateContent(text);
        final currentContent = note.markdownContent;
        final separator =
            addNewline && currentContent.isNotEmpty && validatedText.isNotEmpty
                ? '\n'
                : '';
        final updatedContent = '$currentContent$separator$validatedText';
        _validateContent(updatedContent);
        await _approveWrite(
          client: client,
          permission: McpPermission.append,
          action: 'append_to_note',
          note: note,
          summary: 'Append text to "${note.title}"',
          before: currentContent,
          after: updatedContent,
          sessionGeneration: sessionGeneration,
        );
        _ensureOperationAccess(client, sessionGeneration);
        final updated = await _notesRepository.updateNoteIfUnchanged(
          note.copyWith(
            content: updatedContent,
            formatVersion: 2,
            isChecklist: false,
            checklistItems: const [],
          ),
          expectedModifiedAt: note.modifiedAt,
        );
        if (updated == null) await _throwCurrentConflict(note.uuid);
        _afterMutation('MCP note appended');
        return {
          'note': _noteJson(
            updated,
            includeContent:
                client.permissions.contains(McpPermission.readContent),
          ),
        };
      },
      approvalHandledByOperation: true,
    );
  }

  Future<Map<String, dynamic>> updateNote({
    required String clientId,
    required String noteId,
    required String expectedModifiedAt,
    String? title,
    String? content,
    List<String>? tags,
    List<String>? aliases,
    String? color,
    bool? pinned,
    bool? checklist,
    List<Map<String, dynamic>>? checklistItems,
  }) {
    return _execute(
      clientId: clientId,
      action: 'update_note',
      noteId: noteId,
      permission: McpPermission.edit,
      operation: (client, sessionGeneration) async {
        final note = await _requireVisibleNote(client, noteId);
        _ensureExpectedVersion(note, expectedModifiedAt);
        final nextTags = tags == null ? note.tags : _validateTags(tags);
        final nextAliases =
            aliases == null ? note.aliases : _validateAliases(aliases);
        _ensureWritableTags(client, nextTags);
        final items = checklistItems == null
            ? note.checklistItems
            : _parseChecklistItems(checklistItems);
        final nextContent = _validateContent(
          checklist == true || checklistItems != null
              ? _checklistMarkdown(items)
              : content ?? note.markdownContent,
        );
        final updated = note.copyWith(
          title: title == null ? note.title : _validateTitle(title),
          content: nextContent,
          formatVersion: 2,
          tags: nextTags,
          aliases: nextAliases,
          color: color == null ? note.color : _parseColor(color),
          isPinned: pinned ?? note.isPinned,
          isChecklist: false,
          checklistItems: const [],
        );
        await _approveWrite(
          client: client,
          permission: McpPermission.edit,
          action: 'update_note',
          note: note,
          summary: 'Edit "${note.title}"',
          before: _approvalSnapshot(note),
          after: _approvalSnapshot(updated),
          sessionGeneration: sessionGeneration,
        );
        _ensureOperationAccess(client, sessionGeneration);
        final saved = await _notesRepository.updateNoteIfUnchanged(
          updated,
          expectedModifiedAt: note.modifiedAt,
        );
        if (saved == null) await _throwCurrentConflict(note.uuid);
        _afterMutation('MCP note updated');
        return {
          'note': _noteJson(
            saved,
            includeContent:
                client.permissions.contains(McpPermission.readContent),
          ),
        };
      },
      approvalHandledByOperation: true,
    );
  }

  Future<Map<String, dynamic>> resolveNoteLink({
    required String clientId,
    required String query,
  }) {
    return _execute(
      clientId: clientId,
      action: 'resolve_note_link',
      permission: McpPermission.readMetadata,
      operation: (client, _) async {
        final normalized = query.trim();
        if (normalized.isEmpty || normalized.length > maximumQueryLength) {
          throw const McpOperationException(
            'invalid_input',
            'A note title, alias, or UUID is required.',
          );
        }
        await _notesRepository.initialize();
        final index = KnowledgeIndex.build(await _visibleNotes(client));
        final resolution = index.resolveLink(normalized);
        return {
          'query': normalized,
          'status': resolution.status.name,
          'matches': resolution.matches
              .map((note) => _noteJson(note, includeContent: false))
              .toList(),
        };
      },
    );
  }

  Future<Map<String, dynamic>> listBacklinks({
    required String clientId,
    required String noteId,
    bool includeUnlinkedMentions = true,
  }) {
    return _execute(
      clientId: clientId,
      action: 'list_backlinks',
      noteId: noteId,
      permission: McpPermission.readContent,
      operation: (client, _) async {
        final note = await _requireVisibleNote(client, noteId);
        final index = KnowledgeIndex.build(await _visibleNotes(client));
        final backlinks = index.backlinksFor(
          note.uuid,
          includeUnlinkedMentions: includeUnlinkedMentions,
        );
        return {
          'note_id': note.uuid,
          'backlinks': backlinks
              .map(
                (backlink) => {
                  'source': _noteJson(
                    backlink.source,
                    includeContent: false,
                  ),
                  'label': backlink.label,
                  if (backlink.heading != null) 'heading': backlink.heading,
                  'unlinked_mention': backlink.isUnlinkedMention,
                },
              )
              .toList(),
        };
      },
    );
  }

  Future<Map<String, dynamic>> getNoteOutline({
    required String clientId,
    required String noteId,
  }) {
    return _execute(
      clientId: clientId,
      action: 'get_note_outline',
      noteId: noteId,
      permission: McpPermission.readContent,
      operation: (client, _) async {
        final note = await _requireVisibleNote(client, noteId);
        final parsed = _knowledgeParser.parse(note.markdownContent);
        return {
          'note_id': note.uuid,
          'modified_at': note.modifiedAt.toUtc().toIso8601String(),
          'headings': parsed.headings
              .map(
                (heading) => {
                  'level': heading.level,
                  'title': heading.title,
                  'anchor': heading.anchor,
                },
              )
              .toList(),
          'blocks': parsed.blocks
              .map((block) => {'id': block.id, 'text': block.text})
              .toList(),
          'tasks': {
            'total': parsed.taskCount,
            'completed': parsed.completedTaskCount,
          },
        };
      },
    );
  }

  Future<Map<String, dynamic>> updateNoteSection({
    required String clientId,
    required String noteId,
    required String expectedModifiedAt,
    required String heading,
    required String content,
  }) {
    return _execute(
      clientId: clientId,
      action: 'update_note_section',
      noteId: noteId,
      permission: McpPermission.edit,
      operation: (client, sessionGeneration) async {
        final note = await _requireVisibleNote(client, noteId);
        _ensureExpectedVersion(note, expectedModifiedAt);
        final validatedContent = _validateContent(content);
        late final String updatedContent;
        try {
          updatedContent = _knowledgeParser.replaceSection(
            note.markdownContent,
            heading: heading,
            replacement: validatedContent,
          );
        } on KnowledgeParseException catch (error) {
          throw McpOperationException(
            error.code,
            error.code == 'heading_ambiguous'
                ? 'More than one heading matches. Use the unique outline anchor.'
                : 'The requested heading does not exist.',
          );
        }
        _validateContent(updatedContent);
        await _approveWrite(
          client: client,
          permission: McpPermission.edit,
          action: 'update_note_section',
          note: note,
          summary: 'Edit section "$heading" in "${note.title}"',
          before: note.markdownContent,
          after: updatedContent,
          sessionGeneration: sessionGeneration,
        );
        _ensureOperationAccess(client, sessionGeneration);
        final saved = await _notesRepository.updateNoteIfUnchanged(
          note.copyWith(
            content: updatedContent,
            formatVersion: 2,
            isChecklist: false,
            checklistItems: const [],
          ),
          expectedModifiedAt: note.modifiedAt,
        );
        if (saved == null) await _throwCurrentConflict(note.uuid);
        _afterMutation('MCP note section updated');
        return {
          'note': _noteJson(
            saved,
            includeContent:
                client.permissions.contains(McpPermission.readContent),
          ),
        };
      },
      approvalHandledByOperation: true,
    );
  }

  Future<Map<String, dynamic>> getOrCreateDailyNote({
    required String clientId,
    required String date,
    String? template,
  }) {
    return _execute(
      clientId: clientId,
      action: 'get_or_create_daily_note',
      permission: McpPermission.create,
      operation: (client, sessionGeneration) async {
        final day = _parseJournalDate(date);
        await _notesRepository.initialize();
        final existing = await _notesRepository.findJournalNote(day);
        if (existing != null) {
          if (!_canAccessNote(client, existing)) {
            throw const McpOperationException(
              'note_not_found',
              'The daily note is outside this AI app scope.',
            );
          }
          return {
            'created': false,
            'note': _noteJson(
              existing,
              includeContent:
                  client.permissions.contains(McpPermission.readContent),
            ),
          };
        }

        const tags = ['journal'];
        _ensureWritableTags(client, tags);
        final templateBody = template ??
            builtInNoteTemplates
                .firstWhere((candidate) => candidate.id == 'daily-log')
                .content;
        final content = _validateContent(expandNoteTemplate(templateBody, day));
        await _approveWrite(
          client: client,
          permission: McpPermission.create,
          action: 'get_or_create_daily_note',
          summary: 'Create daily note ${dailyNoteTitle(day)}',
          after: content,
          sessionGeneration: sessionGeneration,
        );
        _ensureOperationAccess(client, sessionGeneration);
        final result = await _notesRepository.getOrCreateJournalNote(
          date: day,
          title: dailyNoteTitle(day),
          content: content,
          tags: tags,
        );
        final note = result.note;
        if (!result.created && !_canAccessNote(client, note)) {
          throw const McpOperationException(
            'note_not_found',
            'The daily note is outside this AI app scope.',
          );
        }
        if (!result.created) {
          return {
            'created': false,
            'note': _noteJson(
              note,
              includeContent:
                  client.permissions.contains(McpPermission.readContent),
            ),
          };
        }
        _afterMutation('MCP daily note created');
        return {
          'created': true,
          'note': _noteJson(
            note,
            includeContent:
                client.permissions.contains(McpPermission.readContent),
          ),
        };
      },
      approvalHandledByOperation: true,
    );
  }

  Future<Map<String, dynamic>> appendToDailyNote({
    required String clientId,
    required String date,
    required String text,
    String? expectedModifiedAt,
  }) {
    return _execute(
      clientId: clientId,
      action: 'append_to_daily_note',
      permission: McpPermission.append,
      operation: (client, sessionGeneration) async {
        final day = _parseJournalDate(date);
        final validatedText = _validateContent(text);
        await _notesRepository.initialize();
        final existing = await _notesRepository.findJournalNote(day);
        if (existing == null) {
          _ensurePermission(client, McpPermission.create);
          const tags = ['journal'];
          _ensureWritableTags(client, tags);
          await _approveWrite(
            client: client,
            permission: McpPermission.append,
            action: 'append_to_daily_note',
            summary: 'Create and append to daily note ${dailyNoteTitle(day)}',
            after: validatedText,
            sessionGeneration: sessionGeneration,
          );
          _ensureOperationAccess(client, sessionGeneration);
          final result = await _notesRepository.getOrCreateJournalNote(
            date: day,
            title: dailyNoteTitle(day),
            content: validatedText,
            tags: tags,
          );
          if (!result.created) {
            if (!_canAccessNote(client, result.note)) {
              throw const McpOperationException(
                'note_not_found',
                'The daily note is outside this AI app scope.',
              );
            }
            throw McpOperationException(
              'conflict',
              'The daily note was created while this request was pending. '
                  'Read it and retry with expected_modified_at.',
              data: {
                'note_id': result.note.uuid,
                'current_modified_at':
                    result.note.modifiedAt.toUtc().toIso8601String(),
              },
            );
          }
          final created = result.note;
          _afterMutation('MCP daily note created and appended');
          return {
            'created': true,
            'note': _noteJson(
              created,
              includeContent:
                  client.permissions.contains(McpPermission.readContent),
            ),
          };
        }

        if (!_canAccessNote(client, existing)) {
          throw const McpOperationException(
            'note_not_found',
            'The daily note is outside this AI app scope.',
          );
        }
        if (expectedModifiedAt == null) {
          throw const McpOperationException(
            'invalid_input',
            'expected_modified_at is required when the daily note already exists.',
          );
        }
        _ensureExpectedVersion(existing, expectedModifiedAt);
        final separator = existing.markdownContent.isEmpty ? '' : '\n';
        final updatedContent =
            '${existing.markdownContent}$separator$validatedText';
        _validateContent(updatedContent);
        await _approveWrite(
          client: client,
          permission: McpPermission.append,
          action: 'append_to_daily_note',
          note: existing,
          summary: 'Append to daily note ${dailyNoteTitle(day)}',
          before: existing.markdownContent,
          after: updatedContent,
          sessionGeneration: sessionGeneration,
        );
        _ensureOperationAccess(client, sessionGeneration);
        final saved = await _notesRepository.updateNoteIfUnchanged(
          existing.copyWith(
            content: updatedContent,
            formatVersion: 2,
            isChecklist: false,
            checklistItems: const [],
          ),
          expectedModifiedAt: existing.modifiedAt,
        );
        if (saved == null) await _throwCurrentConflict(existing.uuid);
        _afterMutation('MCP daily note appended');
        return {
          'created': false,
          'note': _noteJson(
            saved,
            includeContent:
                client.permissions.contains(McpPermission.readContent),
          ),
        };
      },
      approvalHandledByOperation: true,
    );
  }

  Future<Map<String, dynamic>> resolveBlockReference({
    required String clientId,
    required String blockId,
  }) {
    return _execute(
      clientId: clientId,
      action: 'resolve_block_reference',
      permission: McpPermission.readContent,
      operation: (client, _) async {
        final normalized = blockId.trim().replaceFirst(RegExp(r'^\^'), '');
        if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$').hasMatch(normalized)) {
          throw const McpOperationException(
            'invalid_input',
            'A valid block ID is required.',
          );
        }
        final index = KnowledgeIndex.build(await _visibleNotes(client));
        final matches = index.resolveBlock(normalized);
        return {
          'block_id': normalized,
          'status': matches.isEmpty
              ? 'missing'
              : matches.length == 1
                  ? 'resolved'
                  : 'ambiguous',
          'matches': matches
              .map(
                (location) => {
                  'note': _noteJson(location.note, includeContent: false),
                  'text': location.block.text,
                },
              )
              .toList(),
        };
      },
    );
  }

  Future<Map<String, dynamic>> archiveNote({
    required String clientId,
    required String noteId,
    required String expectedModifiedAt,
  }) {
    return _execute(
      clientId: clientId,
      action: 'archive_note',
      noteId: noteId,
      permission: McpPermission.archive,
      operation: (client, sessionGeneration) async {
        final note = await _requireVisibleNote(client, noteId);
        _ensureExpectedVersion(note, expectedModifiedAt);
        await _approveWrite(
          client: client,
          permission: McpPermission.archive,
          action: 'archive_note',
          note: note,
          summary: 'Archive "${note.title}"',
          sessionGeneration: sessionGeneration,
        );
        _ensureOperationAccess(client, sessionGeneration);
        final saved = await _notesRepository.updateNoteIfUnchanged(
          note.copyWith(isArchived: true),
          expectedModifiedAt: note.modifiedAt,
        );
        if (saved == null) await _throwCurrentConflict(note.uuid);
        _afterMutation('MCP note archived');
        return {'note': _noteJson(saved, includeContent: false)};
      },
      approvalHandledByOperation: true,
    );
  }

  Future<Map<String, dynamic>> deleteNote({
    required String clientId,
    required String noteId,
    required String expectedModifiedAt,
  }) {
    return _execute(
      clientId: clientId,
      action: 'delete_note',
      noteId: noteId,
      permission: McpPermission.delete,
      operation: (client, sessionGeneration) async {
        final note = await _requireVisibleNote(client, noteId);
        _ensureExpectedVersion(note, expectedModifiedAt);
        await _approveWrite(
          client: client,
          permission: McpPermission.delete,
          action: 'delete_note',
          note: note,
          summary: 'Permanently delete "${note.title}"',
          forceApproval: true,
          sessionGeneration: sessionGeneration,
        );
        _ensureOperationAccess(client, sessionGeneration);
        final deleted = await _notesRepository.deleteNoteIfUnchanged(
          note.uuid,
          expectedModifiedAt: note.modifiedAt,
        );
        if (!deleted) await _throwCurrentConflict(note.uuid);
        _afterMutation('MCP note deleted');
        return {'deleted': true, 'note_id': note.uuid};
      },
      approvalHandledByOperation: true,
    );
  }

  Future<T> _execute<T>({
    required String clientId,
    required String action,
    required McpPermission permission,
    required Future<T> Function(
      McpClientRegistration client,
      int sessionGeneration,
    ) operation,
    String? noteId,
    String? approvalSummary,
    String? approvalAfter,
    bool approvalHandledByOperation = false,
  }) async {
    await _registry.initialize();
    final client = _requireClient(clientId);
    var approvalRequested = false;
    final sessionGeneration = _readSession().generation;
    try {
      _ensureSessionGeneration(sessionGeneration);
      _ensurePermission(client, permission);
      if (permission.isWrite && !approvalHandledByOperation) {
        approvalRequested = _requiresApproval(client, permission);
        await _approveWrite(
          client: client,
          permission: permission,
          action: action,
          summary: approvalSummary ?? action,
          after: approvalAfter,
          sessionGeneration: sessionGeneration,
        );
      } else if (permission.isWrite) {
        approvalRequested = _requiresApproval(
          client,
          permission,
          forceApproval: permission == McpPermission.delete,
        );
      }
      final result = await operation(client, sessionGeneration);
      _ensureOperationAccess(client, sessionGeneration);
      await _record(
        client: client,
        action: action,
        noteId: noteId,
        result: McpActivityResult.allowed,
        approvalRequested: approvalRequested,
      );
      _ensureOperationAccess(client, sessionGeneration);
      return result;
    } on McpOperationException catch (error) {
      final effectiveError =
          _operationAccessError(client, sessionGeneration) ?? error;
      await _record(
        client: client,
        action: action,
        noteId: noteId,
        result: effectiveError.code == 'conflict'
            ? McpActivityResult.conflict
            : effectiveError.code == 'approval_denied' ||
                    effectiveError.code == 'approval_timeout' ||
                    effectiveError.code == 'permission_denied'
                ? McpActivityResult.denied
                : McpActivityResult.failed,
        approvalRequested: approvalRequested,
        errorCode: effectiveError.code,
      );
      throw _operationAccessError(client, sessionGeneration) ?? effectiveError;
    } catch (_) {
      final accessError = _operationAccessError(client, sessionGeneration);
      await _record(
        client: client,
        action: action,
        noteId: noteId,
        result: McpActivityResult.failed,
        approvalRequested: approvalRequested,
        errorCode: accessError?.code ?? 'internal_error',
      );
      if (accessError != null) throw accessError;
      throw const McpOperationException(
        'internal_error',
        'GitVault could not complete the note operation.',
      );
    }
  }

  McpClientRegistration _requireClient(String clientId) {
    if (!_registry.enabled) {
      throw const McpOperationException(
        'desktop_unavailable',
        'AI app access is disabled in GitVault Desktop.',
      );
    }
    final client = _registry.getClient(clientId);
    if (client == null) {
      throw const McpOperationException(
        'client_not_paired',
        'The AI app is not connected to GitVault.',
      );
    }
    if (!client.isActive) {
      throw const McpOperationException(
        'client_revoked',
        'This AI app connection was revoked.',
      );
    }
    return client;
  }

  void _ensureSessionGeneration(int expectedGeneration) {
    final error = _sessionAccessError(expectedGeneration);
    if (error != null) throw error;
  }

  void _ensureOperationAccess(
    McpClientRegistration client,
    int sessionGeneration,
  ) {
    final error = _operationAccessError(client, sessionGeneration);
    if (error != null) throw error;
  }

  McpOperationException? _operationAccessError(
    McpClientRegistration initialClient,
    int sessionGeneration,
  ) {
    final sessionError = _sessionAccessError(sessionGeneration);
    if (sessionError != null) return sessionError;
    if (!_registry.enabled) {
      return const McpOperationException(
        'desktop_unavailable',
        'AI app access is disabled in GitVault Desktop.',
      );
    }
    final current = _registry.getClient(initialClient.id);
    if (current == null) {
      return const McpOperationException(
        'client_not_paired',
        'The AI app is not connected to GitVault.',
      );
    }
    if (!current.isActive ||
        current.tokenVerifier != initialClient.tokenVerifier) {
      return const McpOperationException(
        'client_revoked',
        'This AI app credential changed or was revoked.',
      );
    }
    final authorizationChanged =
        !_sameSet(current.permissions, initialClient.permissions) ||
            !_sameSet(current.allowedTags, initialClient.allowedTags) ||
            !_sameSet(current.deniedTags, initialClient.deniedTags) ||
            current.writePolicy != initialClient.writePolicy ||
            !initialClient.approvalExemptPermissions.every(
              current.approvalExemptPermissions.contains,
            );
    if (authorizationChanged) {
      return const McpOperationException(
        'permission_denied',
        'This AI app authorization changed. Reconnect and retry.',
      );
    }
    return null;
  }

  McpOperationException? _sessionAccessError(int expectedGeneration) {
    final session = _readSession();
    if (!session.canAccessVault || session.generation != expectedGeneration) {
      return _vaultLockedError;
    }
    return null;
  }

  void _ensurePermission(
    McpClientRegistration client,
    McpPermission permission,
  ) {
    if (!client.permissions.contains(permission)) {
      throw McpOperationException(
        'permission_denied',
        '${client.displayName} does not have permission to ${permission.label.toLowerCase()}.',
      );
    }
  }

  Future<void> _approveWrite({
    required McpClientRegistration client,
    required McpPermission permission,
    required String action,
    required String summary,
    Note? note,
    String? before,
    String? after,
    bool forceApproval = false,
    required int sessionGeneration,
  }) async {
    _ensureOperationAccess(client, sessionGeneration);
    if (!_requiresApproval(
      client,
      permission,
      forceApproval: forceApproval,
    )) {
      return;
    }
    final decision = await _approvalController.request(
      clientId: client.id,
      clientName: client.displayName,
      permission: permission,
      action: action,
      noteId: note?.uuid,
      noteTitle: note?.title,
      summary: summary,
      before: before,
      after: after,
    );
    _ensureOperationAccess(client, sessionGeneration);
    switch (decision) {
      case McpApprovalDecision.allowOnce:
        return;
      case McpApprovalDecision.allowAlways:
        if (permission != McpPermission.delete) {
          await _registry.allowWriteWithoutApproval(client.id, permission);
          _ensureOperationAccess(client, sessionGeneration);
        }
        return;
      case McpApprovalDecision.timeout:
        throw const McpOperationException(
          'approval_timeout',
          'The GitVault approval request expired.',
        );
      case McpApprovalDecision.cancelled:
      case McpApprovalDecision.deny:
        throw const McpOperationException(
          'approval_denied',
          'The GitVault user denied this operation.',
        );
    }
  }

  bool _requiresApproval(
    McpClientRegistration client,
    McpPermission permission, {
    bool forceApproval = false,
  }) {
    if (forceApproval || permission == McpPermission.delete) return true;
    if (client.writePolicy == McpWritePolicy.allowWhileUnlocked) return false;
    return !client.approvalExemptPermissions.contains(permission);
  }

  Future<Note> _requireVisibleNote(
    McpClientRegistration client,
    String noteId,
  ) async {
    if (noteId.trim().isEmpty || noteId.length > 100) {
      throw const McpOperationException(
        'invalid_input',
        'A valid note ID is required.',
      );
    }
    await _notesRepository.initialize();
    final note = await _notesRepository.getNote(noteId);
    if (note == null || !_canAccessNote(client, note)) {
      throw const McpOperationException(
        'note_not_found',
        'The note does not exist or is outside this AI app scope.',
      );
    }
    return note;
  }

  Future<List<Note>> _visibleNotes(McpClientRegistration client) async {
    final notes = client.permissions.contains(McpPermission.includeArchived)
        ? await _notesRepository.getAllStoredNotes()
        : await _notesRepository.getAllNotes();
    return notes
        .where((note) => !note.isTemplate && _canAccessNote(client, note))
        .toList();
  }

  bool _canAccessNote(McpClientRegistration client, Note note) {
    if (note.isTemplate) return false;
    if (note.isArchived &&
        !client.permissions.contains(McpPermission.includeArchived)) {
      return false;
    }
    final normalized = note.tags.map((tag) => tag.toLowerCase()).toSet();
    if (normalized.any(client.deniedTags.contains)) return false;
    if (client.allowedTags.isEmpty) return true;
    return normalized.any(client.allowedTags.contains);
  }

  void _ensureWritableTags(
    McpClientRegistration client,
    List<String> tags,
  ) {
    final normalized = tags.map((tag) => tag.toLowerCase()).toSet();
    if (normalized.any(client.deniedTags.contains)) {
      throw const McpOperationException(
        'permission_denied',
        'One or more note tags are denied for this AI app.',
      );
    }
    if (client.allowedTags.isNotEmpty &&
        !normalized.any(client.allowedTags.contains)) {
      throw const McpOperationException(
        'permission_denied',
        'The note must include at least one allowed tag.',
      );
    }
  }

  void _ensureExpectedVersion(Note note, String expectedModifiedAt) {
    final expected = DateTime.tryParse(expectedModifiedAt)?.toUtc();
    final actual = note.modifiedAt.toUtc();
    if (expected == null) {
      throw const McpOperationException(
        'invalid_input',
        'expected_modified_at must be a valid ISO-8601 timestamp.',
      );
    }
    if (!expected.isAtSameMomentAs(actual)) {
      throw McpOperationException(
        'conflict',
        'The note changed after it was read. Read it again before editing.',
        data: {
          'note_id': note.uuid,
          'current_modified_at': actual.toIso8601String(),
        },
      );
    }
  }

  Future<Never> _throwCurrentConflict(String noteId) async {
    final current = await _notesRepository.getNote(noteId);
    throw McpOperationException(
      'conflict',
      'The note changed while this operation was pending. Read it again before editing.',
      data: {
        'note_id': noteId,
        if (current != null)
          'current_modified_at': current.modifiedAt.toUtc().toIso8601String(),
        if (current == null) 'deleted': true,
      },
    );
  }

  String _validateTitle(String title) {
    final value = title.trim();
    if (value.length > maximumTitleLength) {
      throw const McpOperationException(
        'invalid_input',
        'Note title is too long.',
      );
    }
    return value;
  }

  String _validateContent(String content) {
    if (content.length > maximumContentLength) {
      throw const McpOperationException(
        'invalid_input',
        'Note content exceeds the 256 KiB limit.',
      );
    }
    return content;
  }

  List<String> _validateTags(Iterable<String> tags) {
    final result = tags
        .map((tag) => tag.trim().replaceFirst(RegExp(r'^#'), ''))
        .where((tag) => tag.isNotEmpty)
        .toSet()
        .toList();
    if (result.length > maximumTagCount ||
        result.any((tag) => tag.length > 80)) {
      throw const McpOperationException(
        'invalid_input',
        'A note can contain up to 50 tags of at most 80 characters.',
      );
    }
    return result;
  }

  List<String> _validateAliases(Iterable<String> aliases) {
    final result = aliases
        .map((alias) => alias.trim())
        .where((alias) => alias.isNotEmpty)
        .toSet()
        .toList();
    if (result.length > 50 || result.any((alias) => alias.length > 200)) {
      throw const McpOperationException(
        'invalid_input',
        'A note can contain up to 50 aliases of at most 200 characters.',
      );
    }
    return result;
  }

  NoteColor _parseColor(String value) {
    return NoteColor.values.firstWhere(
      (color) => color.name == value.toLowerCase(),
      orElse: () => throw const McpOperationException(
        'invalid_input',
        'Unknown note color.',
      ),
    );
  }

  List<ChecklistItem> _parseChecklistItems(
    List<Map<String, dynamic>> items,
  ) {
    if (items.length > 500) {
      throw const McpOperationException(
        'invalid_input',
        'A checklist can contain at most 500 items.',
      );
    }
    return items.map((item) {
      final text = item['text'];
      if (text is! String || text.length > 2000) {
        throw const McpOperationException(
          'invalid_input',
          'Checklist item text is invalid.',
        );
      }
      return ChecklistItem(
        text: text,
        isChecked: item['is_checked'] as bool? ?? false,
      );
    }).toList();
  }

  String _checklistMarkdown(List<ChecklistItem> items) {
    return items.map((item) {
      final marker = item.isChecked ? 'x' : ' ';
      return '- [$marker] ${item.text}';
    }).join('\n');
  }

  DateTime _parseJournalDate(String value) {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
      throw const McpOperationException(
        'invalid_input',
        'date must use YYYY-MM-DD.',
      );
    }
    final parsed = DateTime.tryParse('${value}T00:00:00Z');
    final canonical = parsed == null
        ? ''
        : '${parsed.year.toString().padLeft(4, '0')}-'
            '${parsed.month.toString().padLeft(2, '0')}-'
            '${parsed.day.toString().padLeft(2, '0')}';
    if (parsed == null || canonical != value) {
      throw const McpOperationException(
        'invalid_input',
        'date must be a valid calendar date in YYYY-MM-DD format.',
      );
    }
    return DateTime.utc(parsed.year, parsed.month, parsed.day);
  }

  ({int offset, int limit}) _pagination(int offset, int limit) {
    if (offset < 0 || limit < 1 || limit > maximumPageSize) {
      throw const McpOperationException(
        'invalid_input',
        'offset must be non-negative and limit must be between 1 and 100.',
      );
    }
    return (offset: offset, limit: limit);
  }

  Map<String, dynamic> _noteJson(
    Note note, {
    required bool includeContent,
    bool contentAsSnippet = false,
  }) {
    final markdownContent = note.markdownContent;
    final content = contentAsSnippet && markdownContent.length > 500
        ? '${markdownContent.substring(0, 500)}...'
        : markdownContent;
    return {
      'uuid': note.uuid,
      'title': note.title,
      if (includeContent) 'content': content,
      'color': note.color.name,
      'is_pinned': note.isPinned,
      'tags': note.tags,
      'aliases': note.aliases,
      'format': 'markdown',
      'format_version': 2,
      'is_checklist': false,
      if (note.journalDate != null)
        'journal_date': note.journalDate!.toUtc().toIso8601String(),
      'is_archived': note.isArchived,
      'created_at': note.createdAt.toUtc().toIso8601String(),
      'modified_at': note.modifiedAt.toUtc().toIso8601String(),
    };
  }

  String _approvalSnapshot(Note note) {
    return [
      'Title: ${note.title}',
      'Tags: ${note.tags.join(', ')}',
      'Aliases: ${note.aliases.join(', ')}',
      'Pinned: ${note.isPinned}',
      'Archived: ${note.isArchived}',
      '',
      note.markdownContent,
    ].join('\n');
  }

  void _afterMutation(String reason) {
    _onMutation?.call();
    ForegroundSyncService.scheduleSync(
      reason: reason,
      debounce: const Duration(seconds: 1),
    );
  }

  Future<void> _record({
    required McpClientRegistration client,
    required String action,
    required McpActivityResult result,
    required bool approvalRequested,
    String? noteId,
    String? errorCode,
  }) {
    return _registry.recordActivity(
      McpActivityRecord(
        id: _uuid.v4(),
        timestamp: DateTime.now().toUtc(),
        clientId: client.id,
        clientName: client.displayName,
        action: action,
        noteId: noteId,
        result: result,
        approvalRequested: approvalRequested,
        errorCode: errorCode,
      ),
    );
  }
}
