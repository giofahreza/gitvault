import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../../core/providers/providers.dart';
import '../../core/theme/note_colors.dart';
import '../../data/models/note.dart';
import '../../utils/pointer_focus.dart';
import 'note_editor_screen.dart'; // NoteEditorDialog

/// Google Keep-like notes screen
class NotesScreen extends ConsumerStatefulWidget {
  const NotesScreen({super.key});

  @override
  ConsumerState<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends ConsumerState<NotesScreen> {
  final _searchController = TextEditingController();
  late final FocusNode _searchFocusNode;
  String _searchQuery = '';
  bool _isSearching = false;
  bool _isGridView = true;

  @override
  void initState() {
    super.initState();
    _searchFocusNode = FocusNode(onKeyEvent: _handleSearchKey);
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
        title: !_isSearching
            ? const Text('Notes')
            : PointerFocus(
                focusNode: _searchFocusNode,
                child: TextField(
                  controller: _searchController,
                  focusNode: _searchFocusNode,
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: 'Search notes...',
                    border: InputBorder.none,
                  ),
                  style: const TextStyle(fontSize: 18),
                  onChanged: (value) => setState(() => _searchQuery = value),
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
              onPressed: () => setState(() => _isGridView = !_isGridView),
            ),
          ],
        ],
      ),
      body: notesAsync.when(
        data: (notes) => _buildNotesList(notes),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => Center(child: Text('Error: $err')),
      ),
      floatingActionButton: Semantics(
        label: 'Add note',
        button: true,
        child: FloatingActionButton(
          tooltip: 'Add note',
          onPressed: () => _navigateToEditor(null),
          child: const Icon(Icons.add),
        ),
      ),
    );
  }

  void _startSearch() {
    setState(() {
      _isSearching = true;
      _searchQuery = '';
      _searchController.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocusNode.requestFocus();
    });
  }

  void _clearSearch() {
    setState(() {
      _isSearching = false;
      _searchQuery = '';
      _searchController.clear();
    });
    FocusScope.of(context).unfocus();
  }

  Widget _buildNotesList(List<Note> notes) {
    final query = _searchQuery.trim().toLowerCase();
    final filtered = query.isEmpty
        ? notes
        : notes.where((note) {
            return note.title.toLowerCase().contains(query) ||
                note.content.toLowerCase().contains(query) ||
                note.tags.any((tag) => tag.toLowerCase().contains(query)) ||
                note.checklistItems
                    .any((item) => item.text.toLowerCase().contains(query));
          }).toList();

    if (filtered.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.note_outlined,
                size: 64, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            Text(
              query.isNotEmpty
                  ? 'No matching notes'
                  : 'No notes yet.\nTap + to create one.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 16,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }

    // Separate pinned and unpinned notes
    final pinnedNotes = filtered.where((n) => n.isPinned).toList();
    final unpinnedNotes = filtered.where((n) => !n.isPinned).toList();

    if (_isGridView) {
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 96),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (pinnedNotes.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Text('PINNED',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ),
              _buildMasonryGrid(pinnedNotes),
              if (unpinnedNotes.isNotEmpty) const SizedBox(height: 16),
            ],
            if (unpinnedNotes.isNotEmpty) ...[
              if (pinnedNotes.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Text('OTHERS',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant)),
                ),
              _buildMasonryGrid(unpinnedNotes),
            ],
          ],
        ),
      );
    } else {
      return _buildReorderableListView(pinnedNotes, unpinnedNotes);
    }
  }

  Widget _buildMasonryGrid(List<Note> notes) {
    // Bootstrap-style masonry grid: automatically places notes in shortest column
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final crossAxisCount = width >= 1200
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
            );
          },
        );
      },
    );
  }

  Widget _buildReorderableListView(
      List<Note> pinnedNotes, List<Note> unpinnedNotes) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 96),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (pinnedNotes.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Text('PINNED',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ),
            _buildReorderableSection(pinnedNotes, isPinned: true),
            if (unpinnedNotes.isNotEmpty) const SizedBox(height: 8),
          ],
          if (unpinnedNotes.isNotEmpty) ...[
            if (pinnedNotes.isNotEmpty)
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Text('OTHERS',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ),
            _buildReorderableSection(unpinnedNotes, isPinned: false),
          ],
        ],
      ),
    );
  }

  Widget _buildReorderableSection(List<Note> notes, {required bool isPinned}) {
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      itemCount: notes.length,
      onReorder: (oldIndex, newIndex) {
        _onReorderSection(oldIndex, newIndex, notes);
      },
      itemBuilder: (context, index) {
        final note = notes[index];
        return ReorderableDragStartListener(
          key: ValueKey('reorder_${note.uuid}'),
          index: index,
          child: _NoteListTile(
            note: note,
            onTap: () => _navigateToEditor(note),
            onArchive: () => _archiveNote(note),
            onTogglePin: () => _togglePin(note),
            showDragHandle: true,
          ),
        );
      },
    );
  }

  Future<void> _onReorderSection(
      int oldIndex, int newIndex, List<Note> sectionNotes) async {
    if (newIndex > oldIndex) newIndex--;
    if (oldIndex == newIndex) return;

    final reordered = List<Note>.from(sectionNotes);
    final note = reordered.removeAt(oldIndex);
    reordered.insert(newIndex, note);

    final repo = ref.read(notesRepositoryProvider);
    await repo.initialize();
    await repo.reorderNotes(reordered.map((n) => n.uuid).toList());
    ref.invalidate(notesProvider);
  }

  void _navigateToEditor(Note? note) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NoteEditorDialog(note: note),
      ),
    );
    ref.invalidate(notesProvider);
  }

  Future<void> _togglePin(Note note) async {
    final repo = ref.read(notesRepositoryProvider);
    await repo.initialize();
    final updated = note.copyWith(isPinned: !note.isPinned);
    await repo.updateNote(updated);
    ref.invalidate(notesProvider);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(updated.isPinned ? 'Note pinned' : 'Note unpinned'),
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  Future<void> _archiveNote(Note note) async {
    final repo = ref.read(notesRepositoryProvider);
    await repo.initialize();
    final updated = note.copyWith(isArchived: true);
    await repo.updateNote(updated);
    ref.invalidate(notesProvider);
    ref.invalidate(archivedNotesProvider);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Note archived'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () async {
              final undone = updated.copyWith(isArchived: false);
              await repo.updateNote(undone);
              ref.invalidate(notesProvider);
              ref.invalidate(archivedNotesProvider);
            },
          ),
        ),
      );
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
                  Icon(Icons.archive_outlined,
                      size: 64, color: Theme.of(context).colorScheme.outline),
                  const SizedBox(height: 16),
                  Text(
                    'No archived notes',
                    style: TextStyle(
                        fontSize: 16,
                        color: Theme.of(context).colorScheme.onSurfaceVariant),
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
                          'Delete "${note.title}"? This cannot be undone.'),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('Cancel')),
                        FilledButton(
                          style: FilledButton.styleFrom(
                              backgroundColor:
                                  Theme.of(context).colorScheme.error),
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
  if (note.isChecklist) {
    final checked = note.checklistItems.where((item) => item.isChecked).length;
    return 'Note, $title, checklist $checked of ${note.checklistItems.length} items checked';
  }

  if (note.content.isEmpty) {
    return 'Note, $title';
  }

  return 'Note, $title, ${note.content}';
}

String _noteDisplayTitle(Note note) {
  final title = note.title.trim();
  if (title.isNotEmpty) return title;
  if (note.isChecklist) return 'Checklist';
  return '';
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
          subtitle: Text(
            note.isChecklist
                ? '${note.checklistItems.where((i) => i.isChecked).length}/${note.checklistItems.length} items checked'
                : note.content,
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

  const _NoteCard({
    required this.note,
    required this.onTap,
    required this.onArchive,
    required this.onTogglePin,
  });

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final backgroundColor = note.getBackgroundColor(brightness);
    final textColor = note.getTextColor(brightness);
    final borderColor = note.getBorderColor(brightness);
    final iconColor = NoteColorPalette.getIconColor(brightness);
    final tagBgColor = NoteColorPalette.getTagBackgroundColor(
        note.color.colorIndex, brightness);
    final displayTitle = _noteDisplayTitle(note);
    final showTitleRow = displayTitle.isNotEmpty || note.isPinned;

    return Semantics(
      container: true,
      button: true,
      label: _noteSemanticLabel(note),
      child: Dismissible(
        key: ValueKey('note_${note.uuid}'),
        direction: DismissDirection.horizontal,
        confirmDismiss: (direction) async {
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
                ? Colors.grey.withOpacity(0.3)
                : Colors.blue.withOpacity(0.3),
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
            color: Colors.orange.withOpacity(0.3),
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
                  else if (note.content.isNotEmpty)
                    Text(
                      note.content,
                      style: TextStyle(fontSize: 14, color: textColor),
                      maxLines: 30,
                      overflow: TextOverflow.fade,
                    ),
                  if (note.tags.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: note.tags.take(3).map((tag) {
                        return Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
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
            color: textColor.withOpacity(0.65),
          ),
        ),
        const SizedBox(height: 6),
        ...items.map((item) => Padding(
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
                      color: textColor.withOpacity(item.isChecked ? 0.5 : 0.8),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      item.text.trim().isEmpty ? 'Empty item' : item.text,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.25,
                        color:
                            textColor.withOpacity(item.isChecked ? 0.5 : 1.0),
                        decoration:
                            item.isChecked ? TextDecoration.lineThrough : null,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            )),
        if (remaining > 0)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              '+$remaining more',
              style: TextStyle(
                fontSize: 11,
                color: textColor.withOpacity(0.55),
              ),
            ),
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
  final bool showDragHandle;

  const _NoteListTile({
    super.key,
    required this.note,
    required this.onTap,
    required this.onArchive,
    required this.onTogglePin,
    this.showDragHandle = false,
  });

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final backgroundColor = note.getBackgroundColor(brightness);
    final textColor = note.getTextColor(brightness);
    final iconColor = NoteColorPalette.getIconColor(brightness);
    final displayTitle = _noteDisplayTitle(note);

    String subtitle;
    if (note.isChecklist && note.checklistItems.isNotEmpty) {
      final checked = note.checklistItems.where((i) => i.isChecked).length;
      final total = note.checklistItems.length;
      subtitle = '$checked/$total items checked';
    } else {
      subtitle = note.content;
    }

    return Semantics(
      container: true,
      button: true,
      label: _noteSemanticLabel(note),
      child: Dismissible(
        key: ValueKey('note_list_${note.uuid}'),
        direction: DismissDirection.horizontal,
        confirmDismiss: (direction) async {
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
              ? Colors.grey.withOpacity(0.3)
              : Colors.blue.withOpacity(0.3),
          child: Icon(
            note.isPinned ? Icons.push_pin_outlined : Icons.push_pin,
            color: note.isPinned ? Colors.grey : Colors.blue,
          ),
        ),
        secondaryBackground: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 16),
          color: Colors.orange.withOpacity(0.3),
          child: const Icon(Icons.archive, color: Colors.orange),
        ),
        onDismissed: (_) => onArchive(),
        child: Card(
          color: backgroundColor,
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            leading: note.isPinned
                ? Icon(Icons.push_pin, color: iconColor)
                : note.isChecklist
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
            trailing: showDragHandle
                ? Icon(Icons.drag_handle, color: iconColor)
                : null,
            onTap: onTap,
          ),
        ),
      ),
    );
  }
}
