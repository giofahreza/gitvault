import 'dart:async';

import 'package:uuid/uuid.dart';

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
                        note.content.toLowerCase().contains(queryLower)) ||
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
    String color = 'white',
    bool pinned = false,
    bool checklist = false,
    List<Map<String, dynamic>> checklistItems = const [],
  }) {
    return _execute(
      clientId: clientId,
      action: 'create_note',
      permission: McpPermission.create,
      approvalSummary: 'Create a new note named "${title.trim()}"',
      approvalAfter: content,
      operation: (client, sessionGeneration) async {
        final validatedTitle = _validateTitle(title);
        final validatedContent = _validateContent(content);
        final validatedTags = _validateTags(tags);
        _ensureWritableTags(client, validatedTags);
        final noteColor = _parseColor(color);
        final items = _parseChecklistItems(checklistItems);

        await _notesRepository.initialize();
        _ensureOperationAccess(client, sessionGeneration);
        final note = await _notesRepository.createNote(
          title: validatedTitle,
          content: validatedContent,
          tags: validatedTags,
          color: noteColor,
          isPinned: pinned,
          isChecklist: checklist,
          checklistItems: items,
        );
        _afterMutation('MCP note created');
        return {'note': _noteJson(note, includeContent: true)};
      },
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
        final separator =
            addNewline && note.content.isNotEmpty && validatedText.isNotEmpty
                ? '\n'
                : '';
        final updatedContent = '${note.content}$separator$validatedText';
        _validateContent(updatedContent);
        await _approveWrite(
          client: client,
          permission: McpPermission.append,
          action: 'append_to_note',
          note: note,
          summary: 'Append text to "${note.title}"',
          before: note.content,
          after: updatedContent,
          sessionGeneration: sessionGeneration,
        );
        _ensureOperationAccess(client, sessionGeneration);
        final updated = await _notesRepository.updateNoteIfUnchanged(
          note.copyWith(content: updatedContent),
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
        _ensureWritableTags(client, nextTags);
        final updated = note.copyWith(
          title: title == null ? note.title : _validateTitle(title),
          content: content == null ? note.content : _validateContent(content),
          tags: nextTags,
          color: color == null ? note.color : _parseColor(color),
          isPinned: pinned ?? note.isPinned,
          isChecklist: checklist ?? note.isChecklist,
          checklistItems: checklistItems == null
              ? note.checklistItems
              : _parseChecklistItems(checklistItems),
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
    return notes.where((note) => _canAccessNote(client, note)).toList();
  }

  bool _canAccessNote(McpClientRegistration client, Note note) {
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
    final content = contentAsSnippet && note.content.length > 500
        ? '${note.content.substring(0, 500)}...'
        : note.content;
    return {
      'uuid': note.uuid,
      'title': note.title,
      if (includeContent) 'content': content,
      'color': note.color.name,
      'is_pinned': note.isPinned,
      'tags': note.tags,
      'is_checklist': note.isChecklist,
      if (includeContent && note.isChecklist)
        'checklist_items': note.checklistItems
            .map(
              (item) => {
                'text': item.text,
                'is_checked': item.isChecked,
              },
            )
            .toList(),
      'is_archived': note.isArchived,
      'created_at': note.createdAt.toUtc().toIso8601String(),
      'modified_at': note.modifiedAt.toUtc().toIso8601String(),
    };
  }

  String _approvalSnapshot(Note note) {
    return [
      'Title: ${note.title}',
      'Tags: ${note.tags.join(', ')}',
      'Pinned: ${note.isPinned}',
      'Archived: ${note.isArchived}',
      '',
      note.content,
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
