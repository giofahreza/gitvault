import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:hive/hive.dart';

import '../../core/notes/knowledge_parser.dart';
import '../../core/notes/note_file_service.dart';
import '../../core/notes/note_transfer.dart';
import '../../core/providers/providers.dart';
import '../../core/services/foreground_sync_service.dart';
import '../../core/theme/note_colors.dart';
import '../../core/widgets/vault_lock_action.dart';
import '../../data/models/note.dart';
import '../../utils/pointer_focus.dart';
import 'daily_notes_screen.dart';
import 'knowledge_graph_screen.dart';
import 'note_editor_screen.dart'; // NoteEditorDialog
import 'note_template_picker.dart';
import 'note_templates_screen.dart';

enum _NotesAction { dailyNotes, knowledgeGraph, templates, importMarkdown }

const _knowledgeNoteParser = KnowledgeNoteParser();

/// Google Keep-like notes screen
class NotesScreen extends ConsumerStatefulWidget {
  const NotesScreen({super.key});

  @override
  ConsumerState<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends ConsumerState<NotesScreen> {
  static const _uiSettingsBoxName = 'ui_settings';
  static const _gridViewKey = 'notes_grid_view';

  final _searchController = TextEditingController();
  late final FocusNode _searchFocusNode;
  bool _isSearching = false;
  bool _isGridView = true;
  bool _isSavingReorder = false;
  bool _isPointerReordering = false;
  int _pointerReorderGeneration = 0;
  List<String>? _optimisticPinnedOrder;
  List<String>? _optimisticUnpinnedOrder;
  final Set<String> _optimisticallyArchivedNoteIds = {};

  @override
  void initState() {
    super.initState();
    _searchFocusNode = FocusNode(onKeyEvent: _handleSearchKey);
    unawaited(_loadViewMode());
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleSearchKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape &&
        _isSearching) {
      _clearSearch();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final notesAsync = ref.watch(notesProvider);

    return Scaffold(
      appBar: AppBar(
        excludeHeaderSemantics: _isSearching,
        title: !_isSearching
            ? const Text('Notes')
            : PointerFocus(
                focusNode: _searchFocusNode,
                child: Semantics(
                  label: 'Search notes',
                  child: TextField(
                    controller: _searchController,
                    focusNode: _searchFocusNode,
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: 'Search notes...',
                      border: InputBorder.none,
                    ),
                    style: const TextStyle(fontSize: 18),
                  ),
                ),
              ),
        actions: [
          if (!_isSearching)
            IconButton(
              icon: const Icon(Icons.search),
              tooltip: 'Search',
              onPressed: _startSearch,
            )
          else
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Close search',
              onPressed: _clearSearch,
            ),
          if (!_isSearching) ...[
            IconButton(
              icon: const Icon(Icons.archive_outlined),
              tooltip: 'Archived notes',
              onPressed: () => _showArchivedNotes(),
            ),
            IconButton(
              icon: Icon(_isGridView ? Icons.view_list : Icons.grid_view),
              tooltip: _isGridView ? 'List view' : 'Grid view',
              onPressed: _toggleViewMode,
            ),
            PopupMenuButton<_NotesAction>(
              tooltip: 'More note actions',
              onSelected: _handleNotesAction,
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: _NotesAction.dailyNotes,
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.today_outlined),
                    title: Text('Daily notes'),
                  ),
                ),
                PopupMenuItem(
                  value: _NotesAction.knowledgeGraph,
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.hub_outlined),
                    title: Text('Knowledge graph'),
                  ),
                ),
                PopupMenuItem(
                  value: _NotesAction.templates,
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.description_outlined),
                    title: Text('Templates'),
                  ),
                ),
                PopupMenuItem(
                  value: _NotesAction.importMarkdown,
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.upload_file_outlined),
                    title: Text('Import Markdown'),
                  ),
                ),
              ],
            ),
          ],
          const VaultLockAction(compactOnly: true),
        ],
      ),
      body: notesAsync.when(
        data: (notes) => ValueListenableBuilder<TextEditingValue>(
          valueListenable: _searchController,
          builder: (context, value, _) => _buildNotesList(notes, value.text),
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => Center(child: Text('Error: $err')),
      ),
      floatingActionButton: Semantics(
        label: 'Add note',
        button: true,
        excludeSemantics: true,
        onTap: _createNote,
        child: FloatingActionButton(
          heroTag: 'notes-add-note',
          tooltip: 'Add note',
          onPressed: _createNote,
          child: const Icon(Icons.add),
        ),
      ),
    );
  }

  void _startSearch() {
    setState(() {
      _isSearching = true;
      _searchController.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _requestSearchFocus();
    });
  }

  void _requestSearchFocus() {
    if (mounted && _isSearching) _searchFocusNode.requestFocus();
  }

  Future<void> _loadViewMode() async {
    try {
      final box = await Hive.openBox<String>(_uiSettingsBoxName);
      final stored = box.get(_gridViewKey);
      if (!mounted || stored == null) return;
      setState(() => _isGridView = stored != 'false');
    } catch (_) {
      // Keep the default when UI preferences are unavailable.
    }
  }

  void _toggleViewMode() {
    final next = !_isGridView;
    setState(() => _isGridView = next);
    unawaited(_saveViewMode(next));
  }

  Future<void> _saveViewMode(bool isGridView) async {
    try {
      final box = await Hive.openBox<String>(_uiSettingsBoxName);
      await box.put(_gridViewKey, isGridView.toString());
    } catch (_) {
      // The in-memory choice still applies for this session.
    }
  }

  void _clearSearch() {
    setState(() {
      _isSearching = false;
      _searchController.clear();
    });
    FocusScope.of(context).unfocus();
  }

  Widget _buildNotesList(List<Note> notes, String searchQuery) {
    _pruneArchivedOptimism(notes);
    final query = searchQuery.trim().toLowerCase();
    final visibleNotes = notes
        .where((note) => !_optimisticallyArchivedNoteIds.contains(note.uuid))
        .toList();
    final filtered = query.isEmpty
        ? visibleNotes
        : visibleNotes.where((note) {
            return note.title.toLowerCase().contains(query) ||
                note.markdownContent.toLowerCase().contains(query) ||
                note.tags.any((tag) => tag.toLowerCase().contains(query)) ||
                note.aliases
                    .any((alias) => alias.toLowerCase().contains(query)) ||
                note.checklistItems
                    .any((item) => item.text.toLowerCase().contains(query));
          }).toList();

    if (filtered.isEmpty) {
      return SingleChildScrollView(
        key: const ValueKey('notes_results_scroll'),
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 96),
        child: SizedBox(
          height: math.max(
            0,
            MediaQuery.sizeOf(context).height -
                kToolbarHeight -
                MediaQuery.paddingOf(context).top -
                112,
          ),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.note_outlined,
                  size: 64,
                  color: Theme.of(context).colorScheme.outline,
                ),
                const SizedBox(height: 16),
                Text(
                  query.isNotEmpty
                      ? 'No matching notes'
                      : 'No notes yet.\nTap + to create one.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // Separate pinned and unpinned notes
    final pinnedNotes = _applyOptimisticOrder(
      filtered.where((note) => note.isPinned).toList(),
      isPinned: true,
    );
    final unpinnedNotes = _applyOptimisticOrder(
      filtered.where((note) => !note.isPinned).toList(),
      isPinned: false,
    );

    if (_isGridView) {
      return SingleChildScrollView(
        key: const ValueKey('notes_results_scroll'),
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 96),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (pinnedNotes.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Text(
                  'PINNED',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              _buildMasonryGrid(pinnedNotes),
              if (unpinnedNotes.isNotEmpty) const SizedBox(height: 16),
            ],
            if (unpinnedNotes.isNotEmpty) ...[
              if (pinnedNotes.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Text(
                    'OTHERS',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              _buildMasonryGrid(unpinnedNotes),
            ],
          ],
        ),
      );
    } else {
      return _buildReorderableListView(
        pinnedNotes,
        unpinnedNotes,
        allowReorder: query.isEmpty,
      );
    }
  }

  void _pruneArchivedOptimism(List<Note> notes) {
    if (_optimisticallyArchivedNoteIds.isEmpty) return;
    final activeNoteIds = notes.map((note) => note.uuid).toSet();
    final staleIds = _optimisticallyArchivedNoteIds
        .where((uuid) => !activeNoteIds.contains(uuid))
        .toList();
    if (staleIds.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _optimisticallyArchivedNoteIds.removeAll(staleIds));
    });
  }

  List<Note> _applyOptimisticOrder(
    List<Note> notes, {
    required bool isPinned,
  }) {
    final order = isPinned ? _optimisticPinnedOrder : _optimisticUnpinnedOrder;
    if (order == null) return notes;

    final notesByUuid = {for (final note in notes) note.uuid: note};
    return [
      for (final uuid in order)
        if (notesByUuid.remove(uuid) case final note?) note,
      ...notes.where((note) => notesByUuid.containsKey(note.uuid)),
    ];
  }

  Widget _buildMasonryGrid(List<Note> notes) {
    // Bootstrap-style masonry grid: automatically places notes in shortest column
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final isMobileApp = !kIsWeb &&
            (defaultTargetPlatform == TargetPlatform.android ||
                defaultTargetPlatform == TargetPlatform.iOS);
        final allowPinSwipe = isMobileApp;
        final crossAxisCount = isMobileApp
            ? 1
            : width >= 1200
                ? 4
                : width >= 840
                    ? 3
                    : width >= 520
                        ? 2
                        : 1;

        return MasonryGridView.count(
          crossAxisCount: crossAxisCount,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: notes.length,
          itemBuilder: (context, index) {
            final note = notes[index];
            return _NoteCard(
              note: note,
              onTap: () => _navigateToEditor(note),
              onArchive: () => _archiveNote(note),
              onTogglePin: () => _togglePin(note),
              allowPinSwipe: allowPinSwipe,
            );
          },
        );
      },
    );
  }

  Widget _buildReorderableListView(
    List<Note> pinnedNotes,
    List<Note> unpinnedNotes, {
    required bool allowReorder,
  }) {
    return SingleChildScrollView(
      key: const ValueKey('notes_results_scroll'),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 96),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (pinnedNotes.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Text(
                'PINNED',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            _buildReorderableSection(
              pinnedNotes,
              isPinned: true,
              allowReorder: allowReorder,
            ),
            if (unpinnedNotes.isNotEmpty) const SizedBox(height: 8),
          ],
          if (unpinnedNotes.isNotEmpty) ...[
            if (pinnedNotes.isNotEmpty)
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Text(
                  'OTHERS',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            _buildReorderableSection(
              unpinnedNotes,
              isPinned: false,
              allowReorder: allowReorder,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildReorderableSection(
    List<Note> notes, {
    required bool isPinned,
    required bool allowReorder,
  }) {
    final allowPinSwipe = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    return ExcludeSemantics(
      excluding: _isPointerReordering,
      child: ReorderableListView.builder(
        key: ValueKey(isPinned ? 'pinned-notes' : 'unpinned-notes'),
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        buildDefaultDragHandles: false,
        onReorderStart: _handlePointerReorderStart,
        onReorderEnd: _handlePointerReorderEnd,
        proxyDecorator: (child, _, __) => ExcludeSemantics(
          child: Material(
            elevation: 6,
            color: Colors.transparent,
            child: child,
          ),
        ),
        itemCount: notes.length,
        onReorder: (oldIndex, newIndex) {
          _onReorderSection(oldIndex, newIndex, notes);
        },
        itemBuilder: (context, index) {
          final note = notes[index];
          return _NoteListTile(
            key: ValueKey('reorder_${note.uuid}'),
            note: note,
            onTap: () => _navigateToEditor(note),
            onArchive: () => _archiveNote(note),
            onTogglePin: () => _togglePin(note),
            allowPinSwipe: allowPinSwipe,
            dragHandleIndex: allowReorder ? index : null,
            onDragCanceled: _handlePointerReorderCanceled,
          );
        },
      ),
    );
  }

  void _handlePointerReorderStart(int _) {
    _pointerReorderGeneration++;
    setState(() => _isPointerReordering = true);
  }

  void _handlePointerReorderEnd(int _) {
    _schedulePointerReorderSemanticsRestore();
  }

  void _handlePointerReorderCanceled() {
    _schedulePointerReorderSemanticsRestore();
  }

  void _schedulePointerReorderSemanticsRestore() {
    final generation = _pointerReorderGeneration;
    unawaited(_restorePointerReorderSemantics(generation));
  }

  Future<void> _restorePointerReorderSemantics(int generation) async {
    await Future<void>.delayed(const Duration(milliseconds: 350));
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || generation != _pointerReorderGeneration) return;
    setState(() => _isPointerReordering = false);
  }

  void _onReorderSection(
    int oldIndex,
    int newIndex,
    List<Note> sectionNotes,
  ) {
    if (_isSavingReorder) return;
    if (newIndex > oldIndex) newIndex--;
    if (oldIndex == newIndex) return;

    final reordered = List<Note>.from(sectionNotes);
    final note = reordered.removeAt(oldIndex);
    reordered.insert(newIndex, note);
    final orderedUuids = reordered.map((note) => note.uuid).toList();

    setState(() {
      _isSavingReorder = true;
      if (note.isPinned) {
        _optimisticPinnedOrder = orderedUuids;
      } else {
        _optimisticUnpinnedOrder = orderedUuids;
      }
    });

    unawaited(
      _persistReorderedSection(
        orderedUuids,
        isPinned: note.isPinned,
      ),
    );
  }

  Future<void> _persistReorderedSection(
    List<String> orderedUuids, {
    required bool isPinned,
  }) async {
    try {
      final repo = ref.read(notesRepositoryProvider);
      await repo.initialize();
      await repo.reorderNotes(orderedUuids);
      ForegroundSyncService.scheduleSync(
        reason: 'notes reordered',
        debounce: const Duration(seconds: 2),
      );

      // ReorderableListView removes its drag overlay immediately after
      // onReorder returns. Refreshing the provider in that same frame can
      // leave Flutter Web's accessibility tree pointing at detached nodes.
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) {
        final _ = await ref.refresh(notesProvider.future);
      }
    } catch (error) {
      _showError('Could not reorder notes', error);
    } finally {
      if (mounted) {
        setState(() {
          _isSavingReorder = false;
          if (isPinned) {
            _optimisticPinnedOrder = null;
          } else {
            _optimisticUnpinnedOrder = null;
          }
        });
      }
    }
  }

  Future<void> _createNote() async {
    try {
      final seed = await showNoteTemplatePicker(
        context,
        ref,
        date: DateTime.now(),
      );
      if (seed == null || !mounted) return;
      await _navigateToEditor(null, seed: seed);
    } catch (error) {
      _showError('Could not load note templates', error);
    }
  }

  Future<void> _navigateToEditor(
    Note? note, {
    NoteCreationSeed? seed,
  }) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NoteEditorDialog(
          note: note,
          initialTitle: seed?.title ?? '',
          initialContent: seed?.content ?? '',
          initialColor: seed?.color ?? NoteColor.white,
          initialTags: seed?.tags ?? const [],
          initialAliases: seed?.aliases ?? const [],
        ),
      ),
    );
    _invalidateNoteProviders();
  }

  Future<void> _handleNotesAction(_NotesAction action) async {
    switch (action) {
      case _NotesAction.dailyNotes:
        await _openNotesFeature(const DailyNotesScreen());
        return;
      case _NotesAction.knowledgeGraph:
        await _openNotesFeature(const KnowledgeGraphScreen());
        return;
      case _NotesAction.templates:
        await _openNotesFeature(const NoteTemplatesScreen());
        return;
      case _NotesAction.importMarkdown:
        await _importMarkdown();
        return;
    }
  }

  Future<void> _openNotesFeature(Widget screen) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => screen),
    );
    _invalidateNoteProviders();
  }

  Future<void> _importMarkdown() async {
    try {
      final picked = await const NoteFileService().pickMarkdown();
      if (picked == null || !mounted) return;
      final imported = const NoteTransferCodec().decodeBytes(
        picked.bytes,
        fallbackName: picked.name,
      );
      final repository = ref.read(notesRepositoryProvider);
      await repository.initialize();

      var journalDate = imported.journalDate;
      if (journalDate != null) {
        final existing = await repository.findJournalNote(journalDate);
        if (existing != null && mounted) {
          final importAsRegular = await showDialog<bool>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              title: const Text('Daily note already exists'),
              content: Text(
                '"${existing.title}" already uses this date. Import the file '
                'as a regular note instead?',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('Import note'),
                ),
              ],
            ),
          );
          if (importAsRegular != true) return;
          journalDate = null;
        }
      }

      final note = await repository.createNote(
        title: imported.title,
        content: imported.content,
        formatVersion: 2,
        color: imported.color,
        isPinned: imported.isPinned,
        tags: imported.tags,
        aliases: imported.aliases,
        journalDate: journalDate,
      );
      _invalidateNoteProviders();
      ForegroundSyncService.scheduleSync(
        reason: 'Markdown note imported',
        debounce: const Duration(seconds: 2),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Imported ${picked.name}')),
      );
      await _navigateToEditor(note);
    } on NoteTransferException catch (error) {
      _showError('Could not import Markdown (${error.code})');
    } catch (error) {
      _showError('Could not import Markdown', error);
    }
  }

  void _invalidateNoteProviders() {
    ref.invalidate(notesProvider);
    ref.invalidate(archivedNotesProvider);
    ref.invalidate(noteTemplatesProvider);
    ref.invalidate(knowledgeIndexProvider);
  }

  void _showError(String message, [Object? error]) {
    if (!mounted) return;
    final detail = error == null ? message : '$message: $error';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(detail)),
    );
  }

  Future<void> _togglePin(Note note) async {
    final repo = ref.read(notesRepositoryProvider);
    await repo.initialize();
    final updated = note.copyWith(isPinned: !note.isPinned);
    await repo.updateNote(updated);
    ref.invalidate(notesProvider);
    ForegroundSyncService.scheduleSync(
      reason: 'note pin changed',
      debounce: const Duration(seconds: 2),
    );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(updated.isPinned ? 'Note pinned' : 'Note unpinned'),
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  void _archiveNote(Note note) {
    setState(() => _optimisticallyArchivedNoteIds.add(note.uuid));
    unawaited(_persistArchiveNote(note));
  }

  Future<void> _persistArchiveNote(Note note) async {
    final repo = ref.read(notesRepositoryProvider);
    try {
      await repo.initialize();
      final updated = note.copyWith(isArchived: true);
      await repo.updateNote(updated);
      ref.invalidate(notesProvider);
      ref.invalidate(archivedNotesProvider);
      ForegroundSyncService.scheduleSync(
        reason: 'note archived',
        debounce: const Duration(seconds: 2),
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Note archived'),
            action: SnackBarAction(
              label: 'Undo',
              onPressed: () async {
                final undone = updated.copyWith(isArchived: false);
                await repo.updateNote(undone);
                if (mounted) {
                  setState(
                    () => _optimisticallyArchivedNoteIds.remove(note.uuid),
                  );
                }
                ref.invalidate(notesProvider);
                ref.invalidate(archivedNotesProvider);
                ForegroundSyncService.scheduleSync(
                  reason: 'note archive undone',
                  debounce: const Duration(seconds: 2),
                );
              },
            ),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        setState(() => _optimisticallyArchivedNoteIds.remove(note.uuid));
        _showError('Could not archive note', error);
      }
    }
  }

  void _showArchivedNotes() {
    if (MediaQuery.sizeOf(context).width >= 720) {
      showDialog(
        context: context,
        builder: (_) => const Dialog(
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            width: 720,
            height: 620,
            child: _ArchivedNotesScreen(embedded: true),
          ),
        ),
      );
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const _ArchivedNotesScreen(),
      ),
    );
  }
}

/// Screen showing archived notes
class _ArchivedNotesScreen extends ConsumerWidget {
  final bool embedded;

  const _ArchivedNotesScreen({this.embedded = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final archivedAsync = ref.watch(archivedNotesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Archived Notes'),
        automaticallyImplyLeading: !embedded,
        actions: [
          if (embedded)
            IconButton(
              tooltip: 'Close',
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.of(context).pop(),
            ),
        ],
      ),
      body: archivedAsync.when(
        data: (notes) {
          if (notes.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.archive_outlined,
                    size: 64,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No archived notes',
                    style: TextStyle(
                      fontSize: 16,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 96),
            itemCount: notes.length,
            itemBuilder: (context, index) {
              final note = notes[index];
              return _ArchivedNoteCard(
                note: note,
                onUnarchive: () async {
                  final repo = ref.read(notesRepositoryProvider);
                  await repo.initialize();
                  final updated = note.copyWith(isArchived: false);
                  await repo.updateNote(updated);
                  ref.invalidate(notesProvider);
                  ref.invalidate(archivedNotesProvider);
                  ForegroundSyncService.scheduleSync(
                    reason: 'note unarchived',
                    debounce: const Duration(seconds: 2),
                  );

                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Note unarchived')),
                    );
                  }
                },
                onDelete: () async {
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Delete Note'),
                      content: Text(
                        'Delete "${note.title}"? This cannot be undone.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('Cancel'),
                        ),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor:
                                Theme.of(context).colorScheme.error,
                          ),
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('Delete'),
                        ),
                      ],
                    ),
                  );

                  if (confirm == true) {
                    final repo = ref.read(notesRepositoryProvider);
                    await repo.deleteNote(note.uuid);
                    ref.invalidate(notesProvider);
                    ref.invalidate(archivedNotesProvider);
                    ForegroundSyncService.scheduleSync(
                      reason: 'archived note deleted',
                      debounce: const Duration(seconds: 1),
                    );
                  }
                },
              );
            },
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => Center(child: Text('Error: $err')),
      ),
    );
  }
}

String _noteSemanticLabel(Note note) {
  final displayTitle = _noteDisplayTitle(note);
  final title = displayTitle.isEmpty ? 'Untitled' : displayTitle;
  final preview = _notePreview(note);
  if (preview.taskCount > 0) {
    return 'Note, $title, ${preview.completedTaskCount} of '
        '${preview.taskCount} tasks complete';
  }

  if (preview.text.isEmpty) {
    return 'Note, $title';
  }

  return 'Note, $title, ${preview.text}';
}

String _noteDisplayTitle(Note note) {
  final title = note.title.trim();
  if (title.isNotEmpty) return title;
  if (note.isChecklist) return 'Checklist';
  return '';
}

_NotePreviewData _notePreview(Note note) {
  final parsed = _knowledgeNoteParser.parse(note.markdownContent);
  var text = parsed.plainText;
  if (parsed.headings.isNotEmpty &&
      parsed.headings.first.headingStart == 0 &&
      parsed.headings.first.title.trim().toLowerCase() ==
          note.title.trim().toLowerCase()) {
    final lines = text.split('\n');
    if (lines.isNotEmpty &&
        lines.first.trim().toLowerCase() == note.title.trim().toLowerCase()) {
      text = lines.skip(1).join('\n');
    }
  }
  return _NotePreviewData(
    text: text,
    taskCount: parsed.taskCount,
    completedTaskCount: parsed.completedTaskCount,
  );
}

class _NotePreviewData {
  final String text;
  final int taskCount;
  final int completedTaskCount;

  const _NotePreviewData({
    required this.text,
    required this.taskCount,
    required this.completedTaskCount,
  });

  String get taskSummary => '$completedTaskCount/$taskCount tasks complete';
}

class _ArchivedNoteCard extends StatelessWidget {
  final Note note;
  final VoidCallback onUnarchive;
  final VoidCallback onDelete;

  const _ArchivedNoteCard({
    required this.note,
    required this.onUnarchive,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final backgroundColor = note.getBackgroundColor(brightness);
    final textColor = note.getTextColor(brightness);
    final displayTitle = _noteDisplayTitle(note);
    final preview = _notePreview(note);

    return Semantics(
      container: true,
      label: 'Archived ${_noteSemanticLabel(note)}',
      child: Card(
        color: backgroundColor,
        margin: const EdgeInsets.only(bottom: 8),
        child: ListTile(
          title: Text(
            displayTitle.isEmpty ? 'Untitled' : displayTitle,
            style: TextStyle(fontWeight: FontWeight.bold, color: textColor),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: preview.text.isEmpty && preview.taskCount == 0
              ? null
              : Text(
                  preview.taskCount == 0
                      ? preview.text
                      : '${preview.taskSummary} - ${preview.text}',
                  style: TextStyle(color: textColor),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: Icon(Icons.unarchive, color: textColor),
                tooltip: 'Unarchive',
                onPressed: onUnarchive,
              ),
              IconButton(
                icon: Icon(Icons.delete_outline, color: textColor),
                tooltip: 'Delete',
                onPressed: onDelete,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoteCard extends StatelessWidget {
  final Note note;
  final VoidCallback onTap;
  final VoidCallback onArchive;
  final VoidCallback onTogglePin;
  final bool allowPinSwipe;

  const _NoteCard({
    required this.note,
    required this.onTap,
    required this.onArchive,
    required this.onTogglePin,
    required this.allowPinSwipe,
  });

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final backgroundColor = note.getBackgroundColor(brightness);
    final textColor = note.getTextColor(brightness);
    final borderColor = note.getBorderColor(brightness);
    final iconColor = NoteColorPalette.getIconColor(brightness);
    final tagBgColor = NoteColorPalette.getTagBackgroundColor(
      note.color.colorIndex,
      brightness,
    );
    final displayTitle = _noteDisplayTitle(note);
    final preview = _notePreview(note);
    final showTitleRow = displayTitle.isNotEmpty || note.isPinned;

    return Semantics(
      container: true,
      excludeSemantics: true,
      button: true,
      label: _noteSemanticLabel(note),
      onTap: onTap,
      child: Dismissible(
        key: ValueKey('note_${note.uuid}'),
        direction: allowPinSwipe
            ? DismissDirection.horizontal
            : DismissDirection.endToStart,
        confirmDismiss: (direction) async {
          if (!allowPinSwipe && direction == DismissDirection.startToEnd) {
            return false;
          }
          if (direction == DismissDirection.startToEnd) {
            // Swipe right to pin/unpin
            onTogglePin();
            return false; // Don't actually dismiss
          } else {
            // Swipe left to archive
            return true; // Allow dismiss for archive
          }
        },
        background: Container(
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.only(left: 16),
          decoration: BoxDecoration(
            color: note.isPinned
                ? Colors.grey.withValues(alpha: 0.3)
                : Colors.blue.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            note.isPinned ? Icons.push_pin_outlined : Icons.push_pin,
            color: note.isPinned ? Colors.grey : Colors.blue,
          ),
        ),
        secondaryBackground: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 16),
          decoration: BoxDecoration(
            color: Colors.orange.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Icon(Icons.archive, color: Colors.orange),
        ),
        onDismissed: (_) => onArchive(),
        child: Card(
          color: backgroundColor,
          elevation: 1,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: borderColor, width: 0.5),
          ),
          child: InkWell(
            excludeFromSemantics: true,
            onTap: onTap,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (showTitleRow) ...[
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            displayTitle.isEmpty ? 'Untitled' : displayTitle,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: textColor,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (note.isPinned)
                          Icon(Icons.push_pin, size: 16, color: iconColor),
                      ],
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (note.isChecklist && note.checklistItems.isNotEmpty)
                    _buildChecklistPreview(note, textColor)
                  else if (preview.text.isNotEmpty || preview.taskCount > 0)
                    _buildMarkdownPreview(preview, textColor),
                  if (note.tags.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: note.tags.take(3).map((tag) {
                        return Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: tagBgColor,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            '#$tag',
                            style: TextStyle(fontSize: 10, color: textColor),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildChecklistPreview(Note note, Color textColor) {
    final items = note.checklistItems.take(4).toList();
    final remaining = note.checklistItems.length - items.length;
    final checked = note.checklistItems.where((item) => item.isChecked).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$checked/${note.checklistItems.length} items checked',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: textColor.withValues(alpha: 0.65),
          ),
        ),
        const SizedBox(height: 6),
        ...items.map(
          (item) => Padding(
            padding: const EdgeInsets.only(bottom: 5),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(
                    item.isChecked
                        ? Icons.check_box
                        : Icons.check_box_outline_blank,
                    size: 16,
                    color: textColor.withValues(
                      alpha: item.isChecked ? 0.5 : 0.8,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    item.text.trim().isEmpty ? 'Empty item' : item.text,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.25,
                      color: textColor.withValues(
                        alpha: item.isChecked ? 0.5 : 1.0,
                      ),
                      decoration:
                          item.isChecked ? TextDecoration.lineThrough : null,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (remaining > 0)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              '+$remaining more',
              style: TextStyle(
                fontSize: 11,
                color: textColor.withValues(alpha: 0.55),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildMarkdownPreview(_NotePreviewData preview, Color textColor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (preview.taskCount > 0) ...[
          Text(
            preview.taskSummary,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: textColor.withValues(alpha: 0.65),
            ),
          ),
          if (preview.text.isNotEmpty) const SizedBox(height: 6),
        ],
        if (preview.text.isNotEmpty)
          Text(
            preview.text,
            style: TextStyle(fontSize: 14, color: textColor),
            maxLines: 30,
            overflow: TextOverflow.fade,
          ),
      ],
    );
  }
}

class _NoteListTile extends StatelessWidget {
  final Note note;
  final VoidCallback onTap;
  final VoidCallback onArchive;
  final VoidCallback onTogglePin;
  final bool allowPinSwipe;
  final int? dragHandleIndex;
  final VoidCallback? onDragCanceled;

  const _NoteListTile({
    super.key,
    required this.note,
    required this.onTap,
    required this.onArchive,
    required this.onTogglePin,
    required this.allowPinSwipe,
    this.dragHandleIndex,
    this.onDragCanceled,
  });

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final backgroundColor = note.getBackgroundColor(brightness);
    final textColor = note.getTextColor(brightness);
    final iconColor = NoteColorPalette.getIconColor(brightness);
    final displayTitle = _noteDisplayTitle(note);
    final preview = _notePreview(note);

    final subtitle = preview.taskCount == 0
        ? preview.text
        : '${preview.taskSummary} - ${preview.text}';

    return Dismissible(
      key: ValueKey('note_list_${note.uuid}'),
      direction: allowPinSwipe
          ? DismissDirection.horizontal
          : DismissDirection.endToStart,
      confirmDismiss: (direction) async {
        if (!allowPinSwipe && direction == DismissDirection.startToEnd) {
          return false;
        }
        if (direction == DismissDirection.startToEnd) {
          // Swipe right to pin/unpin
          onTogglePin();
          return false; // Don't actually dismiss
        } else {
          // Swipe left to archive
          return true; // Allow dismiss for archive
        }
      },
      background: Container(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 16),
        color: note.isPinned
            ? Colors.grey.withValues(alpha: 0.3)
            : Colors.blue.withValues(alpha: 0.3),
        child: Icon(
          note.isPinned ? Icons.push_pin_outlined : Icons.push_pin,
          color: note.isPinned ? Colors.grey : Colors.blue,
        ),
      ),
      secondaryBackground: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        color: Colors.orange.withValues(alpha: 0.3),
        child: const Icon(Icons.archive, color: Colors.orange),
      ),
      onDismissed: (_) => onArchive(),
      child: Card(
        color: backgroundColor,
        margin: const EdgeInsets.only(bottom: 8),
        child: ListTile(
          leading: note.isPinned
              ? Icon(Icons.push_pin, color: iconColor)
              : preview.taskCount > 0
                  ? Icon(Icons.checklist, color: iconColor)
                  : null,
          title: Text(
            displayTitle.isEmpty ? 'Untitled' : displayTitle,
            style: TextStyle(fontWeight: FontWeight.bold, color: textColor),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: subtitle.isNotEmpty
              ? Text(
                  subtitle,
                  style: TextStyle(color: textColor),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                )
              : null,
          trailing: dragHandleIndex != null
              ? Listener(
                  onPointerCancel: (_) => onDragCanceled?.call(),
                  child: ReorderableDragStartListener(
                    index: dragHandleIndex!,
                    child: Semantics(
                      container: true,
                      label: 'Reorder note',
                      button: true,
                      excludeSemantics: true,
                      child: SizedBox(
                        width: 48,
                        height: 48,
                        child: Center(
                          child: Icon(Icons.drag_handle, color: iconColor),
                        ),
                      ),
                    ),
                  ),
                )
              : null,
          onTap: onTap,
        ),
      ),
    );
  }
}
