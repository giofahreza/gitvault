import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/providers.dart';
import '../../core/services/foreground_sync_service.dart';
import '../../core/theme/note_colors.dart';
import '../../data/models/note.dart';
import '../../data/repositories/notes_repository.dart';
import '../../utils/auto_bullet.dart';
import '../../utils/pointer_focus.dart';

/// Note editor screen for creating and editing notes
class NoteEditorDialog extends ConsumerStatefulWidget {
  final Note? note;

  const NoteEditorDialog({super.key, this.note});

  @override
  ConsumerState<NoteEditorDialog> createState() => _NoteEditorDialogState();
}

class _NoteEditorDialogState extends ConsumerState<NoteEditorDialog>
    with WidgetsBindingObserver {
  static const _autoSaveDelay = Duration(milliseconds: 600);

  late final TextEditingController _titleController;
  late final TextEditingController _contentController;
  final _newChecklistItemController = TextEditingController();
  final _titleFocus = FocusNode();
  final _contentFocus = FocusNode();
  final _newChecklistItemFocus = FocusNode();
  late final NotesRepository _repository;
  late NoteColor _selectedColor;
  late bool _isPinned;
  late List<String> _tags;
  late bool _isChecklist;
  late List<ChecklistItem> _checklistItems;
  Note? _persistedNote;
  Timer? _autoSaveTimer;
  Future<void> _saveQueue = Future<void>.value();
  final ValueNotifier<int> _saveStatusRevision = ValueNotifier<int>(0);
  int _changeRevision = 0;
  int _savedRevision = 0;
  int _pendingSaveCount = 0;
  bool _hasChanges = false;
  bool _isClosing = false;
  bool _canPop = false;
  bool _discardPendingChanges = false;
  bool _isDisposed = false;
  Object? _lastSaveError;
  String _previousContent = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _repository = ref.read(notesRepositoryProvider);
    _persistedNote = widget.note;
    _titleController = TextEditingController(text: widget.note?.title ?? '');
    _contentController =
        TextEditingController(text: widget.note?.content ?? '');
    _selectedColor = widget.note?.color ?? NoteColor.white;
    _isPinned = widget.note?.isPinned ?? false;
    _tags = List.from(widget.note?.tags ?? []);
    _isChecklist = widget.note?.isChecklist ?? false;
    _checklistItems = List.from(widget.note?.checklistItems ?? []);
    _previousContent = _contentController.text;

    _titleController.addListener(_markChanged);
    _contentController.addListener(_onContentChanged);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _autoSaveTimer?.cancel();
    _isDisposed = true;

    // A route can be disposed without going through its back handler (for
    // example when the biometric gate locks the app). Keep the already-built
    // save operation alive so those last edits still reach encrypted storage.
    if (_hasChanges && !_discardPendingChanges) {
      unawaited(_queueLatestSave(showError: false, updateUi: false));
    }

    _saveStatusRevision.dispose();
    _titleFocus.dispose();
    _contentFocus.dispose();
    _newChecklistItemFocus.dispose();
    _titleController.dispose();
    _contentController.dispose();
    _newChecklistItemController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_queueLatestSave(showError: false));
    }
  }

  void _markChanged() {
    if (_discardPendingChanges) return;

    _changeRevision++;
    _hasChanges = true;
    _lastSaveError = null;
    _notifySaveStatus();
    _scheduleAutoSave();
  }

  void _notifySaveStatus() {
    if (_isDisposed) return;
    _saveStatusRevision.value++;
  }

  void _scheduleAutoSave() {
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(
      _autoSaveDelay,
      () => unawaited(_queueLatestSave(showError: false)),
    );
  }

  void _onContentChanged() {
    _markChanged();

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
    final newText =
        text.substring(0, cursorPos) + nextBullet + text.substring(cursorPos);
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
    final textColor =
        NoteColorPalette.getTextColor(_selectedColor.colorIndex, brightness);
    final hintColor =
        NoteColorPalette.getHintColor(_selectedColor.colorIndex, brightness);
    final tagBgColor = NoteColorPalette.getTagBackgroundColor(
        _selectedColor.colorIndex, brightness);

    return PopScope(
      canPop: _canPop,
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
              onPressed: _isClosing ? null : _toggleChecklist,
            ),
            IconButton(
              icon: Icon(_isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                  color: textColor),
              tooltip: _isPinned ? 'Unpin' : 'Pin',
              onPressed: _isClosing
                  ? null
                  : () {
                      setState(() {
                        _isPinned = !_isPinned;
                        _markChanged();
                      });
                    },
            ),
            IconButton(
              icon: Icon(Icons.palette_outlined, color: textColor),
              tooltip: 'Change color',
              onPressed: _isClosing ? null : _showColorPicker,
            ),
            IconButton(
              icon: Icon(Icons.tag_outlined, color: textColor),
              tooltip: 'Add tag',
              onPressed: _isClosing ? null : _addTag,
            ),
            if (widget.note != null) ...[
              IconButton(
                icon: Icon(Icons.archive_outlined, color: textColor),
                tooltip: 'Archive',
                onPressed: _isClosing ? null : _archiveNote,
              ),
              IconButton(
                icon: Icon(Icons.delete_outline, color: textColor),
                tooltip: 'Delete',
                onPressed: _isClosing ? null : _deleteNote,
              ),
            ],
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(38),
            child: SizedBox(
              height: 38,
              child: Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ValueListenableBuilder<int>(
                    valueListenable: _saveStatusRevision,
                    builder: (_, __, ___) => _buildSaveStatus(textColor),
                  ),
                ),
              ),
            ),
          ),
        ),
        body: AbsorbPointer(
          absorbing: _isClosing,
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                PointerFocus(
                  focusNode: _titleFocus,
                  child: TextField(
                    controller: _titleController,
                    focusNode: _titleFocus,
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
                ),
                if (_tags.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _tags.map((tag) {
                        return Chip(
                          label:
                              Text('#$tag', style: TextStyle(color: textColor)),
                          backgroundColor: tagBgColor,
                          deleteIconColor: textColor,
                          onDeleted: () {
                            setState(() {
                              _tags.remove(tag);
                              _markChanged();
                            });
                          },
                        );
                      }).toList(),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                if (_isChecklist)
                  Expanded(child: _buildChecklistEditor(textColor, hintColor))
                else
                  Expanded(
                    child: PointerFocus(
                      focusNode: _contentFocus,
                      child: TextField(
                        controller: _contentController,
                        focusNode: _contentFocus,
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
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSaveStatus(Color textColor) {
    final style = TextButton.styleFrom(
      foregroundColor: textColor,
      disabledForegroundColor: textColor.withOpacity(0.7),
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    );

    if (_pendingSaveCount > 0) {
      return TextButton.icon(
        onPressed: null,
        style: style,
        icon: SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: textColor,
          ),
        ),
        label: const Text('Saving…'),
      );
    }

    if (_lastSaveError != null) {
      return TextButton.icon(
        onPressed: _isClosing ? null : _manualSave,
        style: style,
        icon: const Icon(Icons.error_outline, size: 18),
        label: const Text('Save failed · Retry'),
      );
    }

    if (_hasChanges) {
      return TextButton.icon(
        onPressed: _isClosing ? null : _manualSave,
        style: style,
        icon: const Icon(Icons.save_outlined, size: 18),
        label: Text(
          _persistedNote == null
              ? 'Not saved yet · Save now'
              : 'Unsaved changes · Save now',
        ),
      );
    }

    if (_persistedNote != null) {
      return TextButton.icon(
        onPressed: null,
        style: style,
        icon: const Icon(Icons.check_circle_outline, size: 18),
        label: const Text('Saved'),
      );
    }

    return TextButton.icon(
      onPressed: null,
      style: style,
      icon: const Icon(Icons.edit_note, size: 18),
      label: const Text('Not saved yet'),
    );
  }

  Future<void> _manualSave() async {
    if (_isClosing || _pendingSaveCount > 0) return;
    await _queueLatestSave(showError: true);
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
        ...unchecked
            .map((i) => _buildChecklistItemTile(i, textColor, hintColor)),
        // Add item row
        ListTile(
          leading: Icon(Icons.add, color: hintColor),
          title: PointerFocus(
            focusNode: _newChecklistItemFocus,
            child: TextField(
              controller: _newChecklistItemController,
              focusNode: _newChecklistItemFocus,
              decoration: InputDecoration(
                hintText: 'Add item',
                hintStyle: TextStyle(color: hintColor),
                border: InputBorder.none,
              ),
              style: TextStyle(fontSize: 16, color: textColor),
              textInputAction: TextInputAction.done,
              onSubmitted: _addChecklistItem,
            ),
          ),
          trailing: IconButton(
            icon: const Icon(Icons.add_circle_outline),
            color: textColor,
            tooltip: 'Add item',
            onPressed: _addChecklistItem,
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
          ...checked
              .map((i) => _buildChecklistItemTile(i, textColor, hintColor)),
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
          _markChanged();
        });
      },
      child: ListTile(
        leading: Checkbox(
          value: item.isChecked,
          onChanged: (value) {
            setState(() {
              _checklistItems[index] = item.copyWith(isChecked: value ?? false);
              _markChanged();
            });
          },
        ),
        title: _ChecklistItemTextField(
          initialText: item.text,
          textColor: textColor,
          isChecked: item.isChecked,
          onChanged: (value) {
            _checklistItems[index] = item.copyWith(text: value);
            _markChanged();
          },
        ),
        contentPadding: EdgeInsets.zero,
        dense: true,
      ),
    );
  }

  void _addChecklistItem([String? value]) {
    final itemText = (value ?? _newChecklistItemController.text).trim();
    if (itemText.isEmpty) return;

    setState(() {
      _checklistItems.add(ChecklistItem(text: itemText));
      _newChecklistItemController.clear();
      _markChanged();
    });
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
        final lines = _contentController.text
            .split('\n')
            .where((l) => l.trim().isNotEmpty);
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
        _isChecklist = true;
      }
      _markChanged();
    });
  }

  void _showColorPicker() {
    final brightness = Theme.of(context).brightness;
    final useDialog = MediaQuery.sizeOf(context).width >= 720;

    if (useDialog) {
      showDialog(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Choose color'),
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: _buildColorPickerGrid(dialogContext, brightness),
          ),
        ),
      );
      return;
    }

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Choose color',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                _buildColorPickerGrid(sheetContext, brightness),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildColorPickerGrid(
      BuildContext pickerContext, Brightness brightness) {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: NoteColor.values.map((color) {
        final colorBg = color.getColorForBrightness(brightness);
        final isSelected = _selectedColor == color;

        return Semantics(
          button: true,
          selected: isSelected,
          label:
              '${_noteColorLabel(color)} note color${isSelected ? ", selected" : ""}',
          child: Tooltip(
            message: _noteColorLabel(color),
            child: InkResponse(
              onTap: () {
                setState(() {
                  _selectedColor = color;
                  _markChanged();
                });
                Navigator.pop(pickerContext);
              },
              radius: 30,
              child: Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  color: colorBg,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isSelected
                        ? Theme.of(pickerContext).colorScheme.primary
                        : NoteColorPalette.getBorderColor(
                            color.colorIndex,
                            brightness,
                          ),
                    width: isSelected ? 3 : 1,
                  ),
                ),
                child: isSelected
                    ? Icon(
                        Icons.check,
                        color: NoteColorPalette.getTextColor(
                          color.colorIndex,
                          brightness,
                        ),
                      )
                    : null,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  String _noteColorLabel(NoteColor color) {
    switch (color) {
      case NoteColor.white:
        return 'White';
      case NoteColor.red:
        return 'Red';
      case NoteColor.orange:
        return 'Orange';
      case NoteColor.yellow:
        return 'Yellow';
      case NoteColor.green:
        return 'Green';
      case NoteColor.teal:
        return 'Teal';
      case NoteColor.blue:
        return 'Blue';
      case NoteColor.purple:
        return 'Purple';
      case NoteColor.pink:
        return 'Pink';
      case NoteColor.brown:
        return 'Brown';
      case NoteColor.gray:
        return 'Gray';
    }
  }

  void _addTag() {
    final tagController = TextEditingController();
    final tagFocus = FocusNode();
    String? error;

    showDialog(
      context: context,
      builder: (context) {
        void submitTag(StateSetter setDialogState) {
          final tag = tagController.text.trim();
          if (tag.isEmpty) {
            setDialogState(() => error = 'Tag name is required');
            return;
          }
          if (_tags.contains(tag)) {
            setDialogState(() => error = 'This tag already exists');
            return;
          }

          setState(() {
            _tags.add(tag);
            _markChanged();
          });
          Navigator.pop(context);
        }

        return StatefulBuilder(
          builder: (dialogContext, setDialogState) => AlertDialog(
            title: const Text('Add Tag'),
            content: PointerFocus(
              focusNode: tagFocus,
              child: TextField(
                controller: tagController,
                focusNode: tagFocus,
                decoration: InputDecoration(
                  labelText: 'Tag name',
                  border: const OutlineInputBorder(),
                  errorText: error,
                ),
                autofocus: true,
                textInputAction: TextInputAction.done,
                onChanged: (_) {
                  if (error != null) setDialogState(() => error = null);
                },
                onSubmitted: (_) => submitTag(setDialogState),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => submitTag(setDialogState),
                child: const Text('Add'),
              ),
            ],
          ),
        );
      },
    ).whenComplete(() {
      tagController.dispose();
      tagFocus.dispose();
    });
  }

  Future<void> _deleteNote() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Note'),
        content: const Text('Delete this note? This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm == true && widget.note != null) {
      if (_isClosing) return;
      if (mounted) setState(() => _isClosing = true);
      _autoSaveTimer?.cancel();
      _discardPendingChanges = true;
      _hasChanges = false;

      try {
        // Do not let an older autosave finish after the deletion and recreate
        // the note.
        await _saveQueue;
        await _repository.initialize();
        await _repository.deleteNote(widget.note!.uuid);
        ForegroundSyncService.scheduleSync(
          reason: 'note deleted',
          debounce: const Duration(seconds: 1),
        );
        await _closeEditor();
      } catch (error) {
        _discardPendingChanges = false;
        _hasChanges = _changeRevision > _savedRevision;
        if (mounted) setState(() => _isClosing = false);
        _showSaveError(error);
      }
    }
  }

  Future<void> _archiveNote() async {
    if (_persistedNote == null || _isClosing) return;

    if (mounted) setState(() => _isClosing = true);
    final saved = await _queueLatestSave(showError: true);
    if (!saved) {
      if (mounted) setState(() => _isClosing = false);
      return;
    }

    try {
      final updated = _persistedNote!.copyWith(isArchived: true);
      _persistedNote = await _repository.updateNote(updated);
      ForegroundSyncService.scheduleSync(
        reason: 'note archived',
        debounce: const Duration(seconds: 1),
      );
      _hasChanges = false;
      _discardPendingChanges = true;
      await _closeEditor();
    } catch (error) {
      if (mounted) setState(() => _isClosing = false);
      _showSaveError(error);
    }
  }

  Future<void> _handleBack() async {
    if (_isClosing) return;
    if (mounted) setState(() => _isClosing = true);

    final saved = await _queueLatestSave(showError: true);
    if (!saved) {
      if (mounted) setState(() => _isClosing = false);
      return;
    }

    _discardPendingChanges = true;
    await _closeEditor();
  }

  Future<void> _closeEditor() async {
    if (!mounted) return;

    // PopScope publishes canPop during build. Wait for that rebuild before
    // asking Navigator to pop, otherwise the just-completed save can still be
    // blocked by the previous canPop=false value.
    setState(() => _canPop = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.pop(context);
  }

  _NoteDraft _buildDraft() {
    return _NoteDraft(
      title: _titleController.text.trim(),
      // Keep whitespace and trailing newlines exactly as the user entered it.
      content: _isChecklist ? '' : _contentController.text,
      color: _selectedColor,
      isPinned: _isPinned,
      tags: List<String>.from(_tags),
      isChecklist: _isChecklist,
      checklistItems: List<ChecklistItem>.from(_checklistItems),
    );
  }

  Future<bool> _queueLatestSave({
    required bool showError,
    bool updateUi = true,
  }) async {
    _autoSaveTimer?.cancel();

    if (!_hasChanges) {
      await _saveQueue;
      return _lastSaveError == null;
    }

    final draft = _buildDraft();
    final revision = _changeRevision;

    // Empty new notes are intentionally discarded. Existing notes can still
    // be cleared, which the previous implementation did not allow.
    final hasChecklistContent =
        draft.checklistItems.any((item) => item.text.trim().isNotEmpty);
    if (_persistedNote == null &&
        draft.title.isEmpty &&
        draft.content.trim().isEmpty &&
        !hasChecklistContent) {
      _savedRevision = revision;
      _hasChanges = false;
      if (updateUi) _notifySaveStatus();
      return true;
    }

    _pendingSaveCount++;
    if (updateUi) _notifySaveStatus();

    final previousSave = _saveQueue;
    final operation = previousSave.then((_) async {
      await _repository.initialize();

      final currentNote = _persistedNote;
      if (currentNote == null) {
        _persistedNote = await _repository.createNote(
          title: draft.title,
          content: draft.content,
          color: draft.color,
          isPinned: draft.isPinned,
          tags: draft.tags,
          isChecklist: draft.isChecklist,
          checklistItems: draft.checklistItems,
        );
      } else {
        final updated = currentNote.copyWith(
          title: draft.title,
          content: draft.content,
          color: draft.color,
          isPinned: draft.isPinned,
          tags: draft.tags,
          isChecklist: draft.isChecklist,
          checklistItems: draft.checklistItems,
        );
        _persistedNote = await _repository.updateNote(updated);
      }
    });

    // Keep the queue usable after a failed write; the caller still receives
    // the original operation so it can report the failure.
    _saveQueue = operation.catchError((_) {});

    try {
      await operation;
      ForegroundSyncService.scheduleSync(
        reason: 'note saved',
        debounce: const Duration(seconds: 8),
      );
      if (revision > _savedRevision) _savedRevision = revision;
      _hasChanges = _changeRevision > _savedRevision;
      _lastSaveError = null;
      return true;
    } catch (error) {
      _lastSaveError = error;
      _hasChanges = true;
      if (showError) _showSaveError(error);
      return false;
    } finally {
      _pendingSaveCount--;
      if (updateUi) _notifySaveStatus();
    }
  }

  void _showSaveError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Could not save note: $error')),
    );
  }
}

class _NoteDraft {
  final String title;
  final String content;
  final NoteColor color;
  final bool isPinned;
  final List<String> tags;
  final bool isChecklist;
  final List<ChecklistItem> checklistItems;

  const _NoteDraft({
    required this.title,
    required this.content,
    required this.color,
    required this.isPinned,
    required this.tags,
    required this.isChecklist,
    required this.checklistItems,
  });
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
  State<_ChecklistItemTextField> createState() =>
      _ChecklistItemTextFieldState();
}

class _ChecklistItemTextFieldState extends State<_ChecklistItemTextField> {
  late final TextEditingController _controller;
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PointerFocus(
      focusNode: _focusNode,
      child: TextField(
        controller: _controller,
        focusNode: _focusNode,
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
      ),
    );
  }
}
