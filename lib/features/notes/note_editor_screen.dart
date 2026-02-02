import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/providers.dart';
import '../../core/theme/note_colors.dart';
import '../../data/models/note.dart';
import '../../utils/auto_bullet.dart';

/// Note editor screen for creating and editing notes
class NoteEditorDialog extends ConsumerStatefulWidget {
  final Note? note;

  const NoteEditorDialog({super.key, this.note});

  @override
  ConsumerState<NoteEditorDialog> createState() => _NoteEditorDialogState();
}

class _NoteEditorDialogState extends ConsumerState<NoteEditorDialog> {
  late final TextEditingController _titleController;
  late final TextEditingController _contentController;
  late NoteColor _selectedColor;
  late bool _isPinned;
  late List<String> _tags;
  late bool _isChecklist;
  late List<ChecklistItem> _checklistItems;
  bool _hasChanges = false;
  String _previousContent = '';

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.note?.title ?? '');
    _contentController = TextEditingController(text: widget.note?.content ?? '');
    _selectedColor = widget.note?.color ?? NoteColor.white;
    _isPinned = widget.note?.isPinned ?? false;
    _tags = List.from(widget.note?.tags ?? []);
    _isChecklist = widget.note?.isChecklist ?? false;
    _checklistItems = List.from(widget.note?.checklistItems ?? []);
    _previousContent = _contentController.text;

    _titleController.addListener(() => _hasChanges = true);
    _contentController.addListener(_onContentChanged);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  void _onContentChanged() {
    _hasChanges = true;

    final text = _contentController.text;
    final prevText = _previousContent;
    _previousContent = text;

    // Only process when a newline was just inserted
    if (text.length <= prevText.length) return;
    final diff = text.length - prevText.length;
    if (diff != 1) return;

    final cursorPos = _contentController.selection.baseOffset;
    if (cursorPos <= 0) return;
    if (text[cursorPos - 1] != '\n') return;

    // Get the previous line
    final beforeNewline = text.substring(0, cursorPos - 1);
    final lastNewline = beforeNewline.lastIndexOf('\n');
    final previousLine = lastNewline >= 0
        ? beforeNewline.substring(lastNewline + 1)
        : beforeNewline;

    final prefix = AutoBullet.detectBulletPrefix(previousLine);
    if (prefix == null) return;

    // If the previous line was an empty bullet (just the prefix), remove it
    if (AutoBullet.isEmptyBullet(previousLine)) {
      // Remove the empty bullet line and the newline
      final lineStart = lastNewline >= 0 ? lastNewline + 1 : 0;
      final newText = text.substring(0, lineStart) + text.substring(cursorPos);
      _previousContent = newText;
      _contentController.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: lineStart),
      );
      return;
    }

    // Insert the next bullet
    final nextBullet = AutoBullet.getNextBullet(prefix);
    final newText = text.substring(0, cursorPos) + nextBullet + text.substring(cursorPos);
    _previousContent = newText;
    _contentController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: cursorPos + nextBullet.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final backgroundColor = _selectedColor.getColorForBrightness(brightness);
    final textColor = NoteColorPalette.getTextColor(_selectedColor.colorIndex, brightness);
    final hintColor = NoteColorPalette.getHintColor(_selectedColor.colorIndex, brightness);
    final tagBgColor = NoteColorPalette.getTagBackgroundColor(_selectedColor.colorIndex, brightness);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _handleBack();
      },
      child: Scaffold(
        backgroundColor: backgroundColor,
        appBar: AppBar(
          backgroundColor: backgroundColor,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          leading: IconButton(
            icon: Icon(Icons.arrow_back, color: textColor),
            onPressed: _handleBack,
          ),
          actions: [
            IconButton(
              icon: Icon(
                _isChecklist ? Icons.notes : Icons.checklist,
                color: textColor,
              ),
              tooltip: _isChecklist ? 'Switch to text' : 'Switch to checklist',
              onPressed: _toggleChecklist,
            ),
            IconButton(
              icon: Icon(_isPinned ? Icons.push_pin : Icons.push_pin_outlined, color: textColor),
              tooltip: _isPinned ? 'Unpin' : 'Pin',
              onPressed: () {
                setState(() {
                  _isPinned = !_isPinned;
                  _hasChanges = true;
                });
              },
            ),
            IconButton(
              icon: Icon(Icons.palette_outlined, color: textColor),
              tooltip: 'Change color',
              onPressed: _showColorPicker,
            ),
            if (widget.note != null) ...[
              IconButton(
                icon: Icon(Icons.archive_outlined, color: textColor),
                tooltip: 'Archive',
                onPressed: _archiveNote,
              ),
              IconButton(
                icon: Icon(Icons.delete_outline, color: textColor),
                tooltip: 'Delete',
                onPressed: _deleteNote,
              ),
            ],
          ],
        ),
        body: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              TextField(
                controller: _titleController,
                decoration: InputDecoration(
                  hintText: 'Title',
                  hintStyle: TextStyle(color: hintColor),
                  border: InputBorder.none,
                ),
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: textColor,
                ),
              ),
              if (_isChecklist)
                Expanded(child: _buildChecklistEditor(textColor, hintColor))
              else
                Expanded(
                  child: TextField(
                    controller: _contentController,
                    decoration: InputDecoration(
                      hintText: 'Note',
                      hintStyle: TextStyle(color: hintColor),
                      border: InputBorder.none,
                    ),
                    style: TextStyle(fontSize: 16, color: textColor),
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                  ),
                ),
              if (_tags.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _tags.map((tag) {
                    return Chip(
                      label: Text('#$tag', style: TextStyle(color: textColor)),
                      backgroundColor: tagBgColor,
                      deleteIconColor: textColor,
                      onDeleted: () {
                        setState(() {
                          _tags.remove(tag);
                          _hasChanges = true;
                        });
                      },
                    );
                  }).toList(),
                ),
              ],
            ],
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _addTag,
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          foregroundColor: Theme.of(context).colorScheme.onPrimaryContainer,
          icon: const Icon(Icons.tag),
          label: const Text('Add Tag'),
        ),
      ),
    );
  }

  Widget _buildChecklistEditor(Color textColor, Color hintColor) {
    // Separate checked and unchecked items
    final unchecked = <int>[];
    final checked = <int>[];
    for (int i = 0; i < _checklistItems.length; i++) {
      if (_checklistItems[i].isChecked) {
        checked.add(i);
      } else {
        unchecked.add(i);
      }
    }

    return ListView(
      children: [
        // Unchecked items
        ...unchecked.map((i) => _buildChecklistItemTile(i, textColor, hintColor)),
        // Add item button
        ListTile(
          leading: Icon(Icons.add, color: hintColor),
          title: TextField(
            decoration: InputDecoration(
              hintText: 'Add item',
              hintStyle: TextStyle(color: hintColor),
              border: InputBorder.none,
            ),
            style: TextStyle(fontSize: 16, color: textColor),
            onSubmitted: (value) {
              if (value.trim().isNotEmpty) {
                setState(() {
                  _checklistItems.add(ChecklistItem(text: value.trim()));
                  _hasChanges = true;
                });
              }
            },
          ),
          contentPadding: EdgeInsets.zero,
        ),
        // Checked items section
        if (checked.isNotEmpty) ...[
          const Divider(),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0),
            child: Text(
              '${checked.length} checked items',
              style: TextStyle(
                fontSize: 14,
                color: hintColor,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          ...checked.map((i) => _buildChecklistItemTile(i, textColor, hintColor)),
        ],
      ],
    );
  }

  Widget _buildChecklistItemTile(int index, Color textColor, Color hintColor) {
    final item = _checklistItems[index];
    return Dismissible(
      key: ValueKey('checklist_item_${index}_${item.text}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        color: Colors.red.withOpacity(0.3),
        child: const Icon(Icons.delete, color: Colors.red),
      ),
      onDismissed: (_) {
        setState(() {
          _checklistItems.removeAt(index);
          _hasChanges = true;
        });
      },
      child: ListTile(
        leading: Checkbox(
          value: item.isChecked,
          onChanged: (value) {
            setState(() {
              _checklistItems[index] = item.copyWith(isChecked: value ?? false);
              _hasChanges = true;
            });
          },
        ),
        title: _ChecklistItemTextField(
          initialText: item.text,
          textColor: textColor,
          isChecked: item.isChecked,
          onChanged: (value) {
            _checklistItems[index] = item.copyWith(text: value);
            _hasChanges = true;
          },
        ),
        contentPadding: EdgeInsets.zero,
        dense: true,
      ),
    );
  }

  void _toggleChecklist() {
    setState(() {
      if (_isChecklist) {
        // Convert checklist to text
        final lines = _checklistItems.map((item) {
          final prefix = item.isChecked ? '[x] ' : '[ ] ';
          return '$prefix${item.text}';
        }).join('\n');
        _contentController.text = lines;
        _previousContent = lines;
        _isChecklist = false;
      } else {
        // Convert text to checklist
        final lines = _contentController.text.split('\n').where((l) => l.trim().isNotEmpty);
        _checklistItems = lines.map((line) {
          final trimmed = line.trim();
          if (trimmed.startsWith('[x] ') || trimmed.startsWith('[X] ')) {
            return ChecklistItem(text: trimmed.substring(4), isChecked: true);
          } else if (trimmed.startsWith('[ ] ')) {
            return ChecklistItem(text: trimmed.substring(4));
          } else if (trimmed.startsWith('- ')) {
            return ChecklistItem(text: trimmed.substring(2));
          }
          return ChecklistItem(text: trimmed);
        }).toList();
        if (_checklistItems.isEmpty) {
          _checklistItems.add(const ChecklistItem(text: ''));
        }
        _isChecklist = true;
      }
      _hasChanges = true;
    });
  }

  void _showColorPicker() {
    final brightness = Theme.of(context).brightness;

    showModalBottomSheet(
      context: context,
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Choose color',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: NoteColor.values.map((color) {
                  final colorBg = color.getColorForBrightness(brightness);
                  final isSelected = _selectedColor == color;

                  return GestureDetector(
                    onTap: () {
                      setState(() {
                        _selectedColor = color;
                        _hasChanges = true;
                      });
                      Navigator.pop(context);
                    },
                    child: Container(
                      width: 50,
                      height: 50,
                      decoration: BoxDecoration(
                        color: colorBg,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isSelected
                              ? Theme.of(context).colorScheme.primary
                              : NoteColorPalette.getBorderColor(color.colorIndex, brightness),
                          width: isSelected ? 3 : 1,
                        ),
                      ),
                      child: isSelected
                          ? Icon(Icons.check, color: NoteColorPalette.getTextColor(color.colorIndex, brightness))
                          : null,
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  void _addTag() {
    showDialog(
      context: context,
      builder: (context) {
        final tagController = TextEditingController();
        return AlertDialog(
          title: const Text('Add Tag'),
          content: TextField(
            controller: tagController,
            decoration: const InputDecoration(
              hintText: 'Tag name',
              border: OutlineInputBorder(),
            ),
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final tag = tagController.text.trim();
                if (tag.isNotEmpty && !_tags.contains(tag)) {
                  setState(() {
                    _tags.add(tag);
                    _hasChanges = true;
                  });
                }
                Navigator.pop(context);
              },
              child: const Text('Add'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _deleteNote() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Note'),
        content: const Text('Delete this note? This cannot be undone.'),
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

    if (confirm == true && widget.note != null) {
      final repo = ref.read(notesRepositoryProvider);
      await repo.deleteNote(widget.note!.uuid);
      if (mounted) Navigator.pop(context);
    }
  }

  Future<void> _archiveNote() async {
    if (widget.note != null) {
      final repo = ref.read(notesRepositoryProvider);
      await repo.initialize();
      final updated = widget.note!.copyWith(isArchived: true);
      await repo.updateNote(updated);
      if (mounted) Navigator.pop(context);
    }
  }

  Future<void> _handleBack() async {
    if (_hasChanges) {
      await _saveNote();
    }
    if (mounted) Navigator.pop(context);
  }

  Future<void> _saveNote() async {
    final title = _titleController.text.trim();
    final content = _isChecklist ? '' : _contentController.text.trim();

    // Don't save empty notes
    if (title.isEmpty && content.isEmpty && _checklistItems.isEmpty) {
      return;
    }

    try {
      final repo = ref.read(notesRepositoryProvider);
      await repo.initialize();

      if (widget.note == null) {
        // Create new note
        await repo.createNote(
          title: title,
          content: content,
          color: _selectedColor,
          isPinned: _isPinned,
          tags: _tags,
          isChecklist: _isChecklist,
          checklistItems: _checklistItems,
        );
      } else {
        // Update existing note
        final updated = widget.note!.copyWith(
          title: title,
          content: content,
          color: _selectedColor,
          isPinned: _isPinned,
          tags: _tags,
          isChecklist: _isChecklist,
          checklistItems: _checklistItems,
        );
        await repo.updateNote(updated);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving note: $e')),
        );
      }
    }
  }
}

/// Stateful text field for individual checklist items to avoid losing focus
class _ChecklistItemTextField extends StatefulWidget {
  final String initialText;
  final Color textColor;
  final bool isChecked;
  final ValueChanged<String> onChanged;

  const _ChecklistItemTextField({
    required this.initialText,
    required this.textColor,
    required this.isChecked,
    required this.onChanged,
  });

  @override
  State<_ChecklistItemTextField> createState() => _ChecklistItemTextFieldState();
}

class _ChecklistItemTextFieldState extends State<_ChecklistItemTextField> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      style: TextStyle(
        fontSize: 16,
        color: widget.textColor,
        decoration: widget.isChecked ? TextDecoration.lineThrough : null,
      ),
      decoration: const InputDecoration(
        border: InputBorder.none,
        isDense: true,
        contentPadding: EdgeInsets.symmetric(vertical: 8),
      ),
      onChanged: widget.onChanged,
    );
  }
}
