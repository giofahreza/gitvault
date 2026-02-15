import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../../core/providers/providers.dart';
import '../../core/theme/note_colors.dart';
import '../../data/models/note.dart';
import 'note_editor_screen.dart'; // NoteEditorDialog

/// Google Keep-like notes screen
class NotesScreen extends ConsumerStatefulWidget {
  const NotesScreen({super.key});

  @override
  ConsumerState<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends ConsumerState<NotesScreen> {
  final _searchController = TextEditingController();
  String _searchQuery = '';
  bool _isGridView = true;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final notesAsync = ref.watch(notesProvider);

    return Scaffold(
      appBar: AppBar(
        title: _searchQuery.isEmpty
            ? const Text('Notes')
            : TextField(
                controller: _searchController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Search notes...',
                  border: InputBorder.none,
                ),
                style: const TextStyle(fontSize: 18),
                onChanged: (value) => setState(() => _searchQuery = value),
              ),
        actions: [
          if (_searchQuery.isEmpty)
            IconButton(
              icon: const Icon(Icons.search),
              tooltip: 'Search',
              onPressed: () {
                setState(() => _searchQuery = ' '); // Trigger search mode
                _searchController.clear();
              },
            )
          else
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: () {
                setState(() {
                  _searchQuery = '';
                  _searchController.clear();
                });
              },
            ),
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
      ),
      body: notesAsync.when(
        data: (notes) => _buildNotesList(notes),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => Center(child: Text('Error: $err')),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _navigateToEditor(null),
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildNotesList(List<Note> notes) {
    final filtered = _searchQuery.trim().isEmpty
        ? notes
        : notes.where((note) {
            final q = _searchQuery.toLowerCase();
            return note.title.toLowerCase().contains(q) ||
                note.content.toLowerCase().contains(q) ||
                note.tags.any((tag) => tag.toLowerCase().contains(q)) ||
                note.checklistItems.any((item) => item.text.toLowerCase().contains(q));
          }).toList();

    if (filtered.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.note_outlined, size: 64, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            Text(
              _searchQuery.trim().isNotEmpty
                  ? 'No matching notes'
                  : 'No notes yet.\nTap + to create one.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
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
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (pinnedNotes.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Text('PINNED', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ),
              _buildMasonryGrid(pinnedNotes),
              if (unpinnedNotes.isNotEmpty) const SizedBox(height: 16),
            ],
            if (unpinnedNotes.isNotEmpty) ...[
              if (pinnedNotes.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Text('OTHERS', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.onSurfaceVariant)),
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
    return MasonryGridView.count(
      crossAxisCount: 2,
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
  }

  Widget _buildReorderableListView(List<Note> pinnedNotes, List<Note> unpinnedNotes) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (pinnedNotes.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Text('PINNED', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ),
            _buildReorderableSection(pinnedNotes, isPinned: true),
            if (unpinnedNotes.isNotEmpty) const SizedBox(height: 8),
          ],
          if (unpinnedNotes.isNotEmpty) ...[
            if (pinnedNotes.isNotEmpty)
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Text('OTHERS', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.onSurfaceVariant)),
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

  Future<void> _onReorderSection(int oldIndex, int newIndex, List<Note> sectionNotes) async {
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
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _ArchivedNotesScreen(),
      ),
    );
  }
}

/// Screen showing archived notes
class _ArchivedNotesScreen extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final archivedAsync = ref.watch(archivedNotesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Archived Notes'),
      ),
      body: archivedAsync.when(
        data: (notes) {
          if (notes.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.archive_outlined, size: 64, color: Theme.of(context).colorScheme.outline),
                  const SizedBox(height: 16),
                  Text(
                    'No archived notes',
                    style: TextStyle(fontSize: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(8),
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
                      content: Text('Delete "${note.title}"? This cannot be undone.'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                        FilledButton(
                          style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
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

    return Card(
      color: backgroundColor,
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        title: Text(
          note.title.isEmpty ? 'Untitled' : note.title,
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
    final tagBgColor = NoteColorPalette.getTagBackgroundColor(note.color.colorIndex, brightness);

    return Dismissible(
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
          color: note.isPinned ? Colors.grey.withOpacity(0.3) : Colors.blue.withOpacity(0.3),
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
                if (note.title.isNotEmpty) ...[
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          note.title,
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
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
    );
  }

  Widget _buildChecklistPreview(Note note, Color textColor) {
    final items = note.checklistItems.take(12).toList();
    final remaining = note.checklistItems.length - items.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ...items.map((item) => Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                children: [
                  Icon(
                    item.isChecked ? Icons.check_box : Icons.check_box_outline_blank,
                    size: 16,
                    color: textColor.withOpacity(item.isChecked ? 0.5 : 0.8),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      item.text,
                      style: TextStyle(
                        fontSize: 12,
                        color: textColor.withOpacity(item.isChecked ? 0.5 : 1.0),
                        decoration: item.isChecked ? TextDecoration.lineThrough : null,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            )),
        if (remaining > 0)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '+$remaining more',
              style: TextStyle(fontSize: 11, color: textColor.withOpacity(0.5)),
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

    String subtitle;
    if (note.isChecklist && note.checklistItems.isNotEmpty) {
      final checked = note.checklistItems.where((i) => i.isChecked).length;
      final total = note.checklistItems.length;
      subtitle = '$checked/$total items checked';
    } else {
      subtitle = note.content;
    }

    return Dismissible(
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
        color: note.isPinned ? Colors.grey.withOpacity(0.3) : Colors.blue.withOpacity(0.3),
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
            note.title.isEmpty ? 'Untitled' : note.title,
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
    );
  }
}
