import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../../core/notes/knowledge_index.dart';
import '../../core/notes/knowledge_parser.dart';
import '../../core/notes/note_file_service.dart';
import '../../core/notes/note_transfer.dart';
import '../../core/providers/providers.dart';
import '../../core/services/foreground_sync_service.dart';
import '../../core/theme/note_colors.dart';
import '../../data/models/note.dart';
import '../../data/repositories/notes_repository.dart';
import '../../utils/auto_bullet.dart';
import '../../utils/pointer_focus.dart';
import 'knowledge_markdown_view.dart';

enum _EditorMode { edit, preview }

enum _EditorAction {
  aliases,
  saveAsTemplate,
  exportMarkdown,
  archive,
  delete,
}

class NoteEditorDialog extends ConsumerStatefulWidget {
  final Note? note;
  final bool templateMode;
  final String initialTitle;
  final String initialContent;
  final NoteColor initialColor;
  final bool initialIsPinned;
  final List<String> initialTags;
  final List<String> initialAliases;
  final DateTime? initialJournalDate;
  final String? initialHeading;
  final int? initialContentOffset;

  const NoteEditorDialog({
    super.key,
    this.note,
    this.templateMode = false,
    this.initialTitle = '',
    this.initialContent = '',
    this.initialColor = NoteColor.white,
    this.initialIsPinned = false,
    this.initialTags = const [],
    this.initialAliases = const [],
    this.initialJournalDate,
    this.initialHeading,
    this.initialContentOffset,
  });

  @override
  ConsumerState<NoteEditorDialog> createState() => _NoteEditorDialogState();
}

class _NoteEditorDialogState extends ConsumerState<NoteEditorDialog>
    with WidgetsBindingObserver {
  static const _autoSaveDelay = Duration(milliseconds: 600);
  static const _parser = KnowledgeNoteParser();

  late final TextEditingController _titleController;
  late final TextEditingController _contentController;
  final _titleFocus = FocusNode();
  final _contentFocus = FocusNode();
  late final NotesRepository _repository;
  late NoteColor _selectedColor;
  late bool _isPinned;
  late List<String> _tags;
  late List<String> _aliases;
  late DateTime? _journalDate;
  late bool _isTemplate;
  Note? _persistedNote;
  KnowledgeIndex? _knowledgeIndex;
  Timer? _autoSaveTimer;
  Future<void> _saveQueue = Future<void>.value();
  final ValueNotifier<int> _saveStatusRevision = ValueNotifier<int>(0);
  int _changeRevision = 0;
  int _savedRevision = 0;
  int _pendingSaveCount = 0;
  int _indexRequest = 0;
  bool _hasChanges = false;
  bool _isClosing = false;
  bool _canPop = false;
  bool _discardPendingChanges = false;
  bool _isDisposed = false;
  bool _loadingIndex = false;
  Object? _lastSaveError;
  String _previousContent = '';
  _EditorMode _mode = _EditorMode.edit;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _repository = ref.read(notesRepositoryProvider);
    _persistedNote = widget.note;
    _titleController = TextEditingController(
      text: widget.note?.title ?? widget.initialTitle,
    );
    _contentController = TextEditingController(
      text: widget.note?.markdownContent ?? widget.initialContent,
    );
    _selectedColor = widget.note?.color ?? widget.initialColor;
    _isPinned = widget.note?.isPinned ?? widget.initialIsPinned;
    _tags = List.from(widget.note?.tags ?? widget.initialTags);
    _aliases = List.from(widget.note?.aliases ?? widget.initialAliases);
    _journalDate = widget.note?.journalDate ?? widget.initialJournalDate;
    _isTemplate = widget.note?.isTemplate ?? widget.templateMode;
    _previousContent = _contentController.text;
    _titleController.addListener(_markChanged);
    _contentController.addListener(_onContentChanged);
    if (widget.note == null &&
        (_titleController.text.isNotEmpty ||
            _contentController.text.trim().isNotEmpty ||
            _tags.isNotEmpty ||
            _aliases.isNotEmpty ||
            _journalDate != null ||
            _isTemplate)) {
      _changeRevision = 1;
      _hasChanges = true;
      _scheduleAutoSave();
    }
    if (widget.initialHeading != null || widget.initialContentOffset != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _jumpToContentTarget(
            heading: widget.initialHeading,
            contentOffset: widget.initialContentOffset,
          );
        }
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _autoSaveTimer?.cancel();
    _isDisposed = true;
    if (_hasChanges && !_discardPendingChanges) {
      unawaited(_queueLatestSave(showError: false, updateUi: false));
    }
    _saveStatusRevision.dispose();
    _titleFocus.dispose();
    _contentFocus.dispose();
    _titleController.dispose();
    _contentController.dispose();
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
    _knowledgeIndex = null;
    _notifySaveStatus();
    _scheduleAutoSave();
  }

  void _notifySaveStatus() {
    if (!_isDisposed) _saveStatusRevision.value++;
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
    final previous = _previousContent;
    _previousContent = text;
    if (text.length - previous.length != 1) return;
    final cursor = _contentController.selection.baseOffset;
    if (cursor <= 0 || text[cursor - 1] != '\n') return;

    final beforeNewline = text.substring(0, cursor - 1);
    final lastNewline = beforeNewline.lastIndexOf('\n');
    final previousLine = lastNewline >= 0
        ? beforeNewline.substring(lastNewline + 1)
        : beforeNewline;
    final prefix = AutoBullet.detectBulletPrefix(previousLine);
    if (prefix == null) return;
    if (AutoBullet.isEmptyBullet(previousLine)) {
      final lineStart = lastNewline >= 0 ? lastNewline + 1 : 0;
      final updated = text.substring(0, lineStart) + text.substring(cursor);
      _setContentValue(updated, lineStart);
      return;
    }
    final next = AutoBullet.getNextBullet(prefix);
    final updated = text.substring(0, cursor) + next + text.substring(cursor);
    _setContentValue(updated, cursor + next.length);
  }

  void _setContentValue(String text, int cursor) {
    _previousContent = text;
    _contentController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: cursor),
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
    final tagBackground = NoteColorPalette.getTagBackgroundColor(
      _selectedColor.colorIndex,
      brightness,
    );

    return PopScope(
      canPop: _canPop,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop) await _handleBack();
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
            tooltip: 'Back',
            onPressed: _handleBack,
          ),
          title: _isTemplate
              ? Text('Template', style: TextStyle(color: textColor))
              : _journalDate == null
                  ? null
                  : Text('Daily note', style: TextStyle(color: textColor)),
          actions: [
            if (!_isTemplate)
              IconButton(
                icon: Icon(
                  _isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                  color: textColor,
                ),
                tooltip: _isPinned ? 'Unpin' : 'Pin',
                onPressed: _isClosing
                    ? null
                    : () {
                        setState(() => _isPinned = !_isPinned);
                        _markChanged();
                      },
              ),
            IconButton(
              icon: Icon(Icons.palette_outlined, color: textColor),
              tooltip: 'Change color',
              onPressed: _isClosing ? null : _showColorPicker,
            ),
            PopupMenuButton<_EditorAction>(
              tooltip: 'More note actions',
              icon: Icon(Icons.more_vert, color: textColor),
              onSelected: _handleEditorAction,
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: _EditorAction.aliases,
                  child: ListTile(
                    leading: Icon(Icons.alternate_email),
                    title: Text('Aliases'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                if (!_isTemplate)
                  const PopupMenuItem(
                    value: _EditorAction.saveAsTemplate,
                    child: ListTile(
                      leading: Icon(Icons.copy_all_outlined),
                      title: Text('Save as template'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                if (!_isTemplate)
                  const PopupMenuItem(
                    value: _EditorAction.exportMarkdown,
                    child: ListTile(
                      leading: Icon(Icons.download_outlined),
                      title: Text('Export Markdown'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                if (!_isTemplate && _persistedNote != null)
                  const PopupMenuItem(
                    value: _EditorAction.archive,
                    child: ListTile(
                      leading: Icon(Icons.archive_outlined),
                      title: Text('Archive'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                if (_persistedNote != null)
                  PopupMenuItem(
                    value: _EditorAction.delete,
                    child: ListTile(
                      leading: const Icon(Icons.delete_outline),
                      title: Text(_isTemplate ? 'Delete template' : 'Delete'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
              ],
            ),
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
          child: SafeArea(
            top: false,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1100),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: Column(
                    children: [
                      PointerFocus(
                        focusNode: _titleFocus,
                        child: TextField(
                          controller: _titleController,
                          focusNode: _titleFocus,
                          decoration: InputDecoration(
                            hintText: _isTemplate ? 'Template name' : 'Title',
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
                      if (_tags.isNotEmpty || _aliases.isNotEmpty)
                        _buildMetadataChips(
                          textColor: textColor,
                          backgroundColor: tagBackground,
                        ),
                      _buildModeBar(textColor),
                      const SizedBox(height: 6),
                      Expanded(
                        child: _mode == _EditorMode.edit
                            ? _buildMarkdownEditor(textColor, hintColor)
                            : _buildMarkdownPreview(textColor),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMetadataChips({
    required Color textColor,
    required Color backgroundColor,
  }) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final tag in _tags)
              InputChip(
                avatar: Icon(Icons.tag, size: 15, color: textColor),
                label: Text(tag, style: TextStyle(color: textColor)),
                backgroundColor: backgroundColor,
                deleteIconColor: textColor,
                onDeleted: () {
                  setState(() => _tags.remove(tag));
                  _markChanged();
                },
              ),
            for (final alias in _aliases)
              InputChip(
                avatar: Icon(Icons.alternate_email, size: 15, color: textColor),
                label: Text(alias, style: TextStyle(color: textColor)),
                backgroundColor: backgroundColor,
                deleteIconColor: textColor,
                onDeleted: () {
                  setState(() => _aliases.remove(alias));
                  _markChanged();
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildModeBar(Color textColor) {
    return Row(
      children: [
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<_EditorMode>(
              showSelectedIcon: false,
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
              ),
              segments: const [
                ButtonSegment(
                  value: _EditorMode.edit,
                  icon: Icon(Icons.edit_outlined, size: 17),
                  label: Text('Edit'),
                ),
                ButtonSegment(
                  value: _EditorMode.preview,
                  icon: Icon(Icons.visibility_outlined, size: 17),
                  label: Text('Preview'),
                ),
              ],
              selected: {_mode},
              onSelectionChanged:
                  _isClosing ? null : (selected) => _setMode(selected.single),
            ),
          ),
        ),
        IconButton(
          tooltip: 'Document outline',
          icon: Icon(Icons.format_list_bulleted, color: textColor),
          onPressed: _showOutline,
        ),
        IconButton(
          tooltip: 'Backlinks',
          icon: Icon(Icons.hub_outlined, color: textColor),
          onPressed: _persistedNote == null ? null : _showBacklinks,
        ),
        IconButton(
          tooltip: 'Add tag',
          icon: Icon(Icons.tag_outlined, color: textColor),
          onPressed: _addTag,
        ),
      ],
    );
  }

  Widget _buildMarkdownEditor(Color textColor, Color hintColor) {
    return Column(
      children: [
        _MarkdownToolbar(
          color: textColor,
          onHeading: () => _prefixSelectedLines('# '),
          onBold: () => _wrapSelection('**', '**', 'bold text'),
          onItalic: () => _wrapSelection('_', '_', 'italic text'),
          onCode: () => _wrapSelection('`', '`', 'code'),
          onBullet: () => _prefixSelectedLines('- '),
          onNumbered: () => _prefixSelectedLines('1. '),
          onTask: () => _prefixSelectedLines('- [ ] '),
          onQuote: () => _prefixSelectedLines('> '),
          onLink: () => _wrapSelection('[', '](https://)', 'link text'),
          onWikiLink: _insertWikiLink,
          onBlockAnchor: _insertBlockAnchor,
        ),
        const Divider(height: 1),
        const SizedBox(height: 6),
        Expanded(
          child: PointerFocus(
            focusNode: _contentFocus,
            child: TextField(
              controller: _contentController,
              focusNode: _contentFocus,
              decoration: InputDecoration(
                hintText: 'Write Markdown...',
                hintStyle: TextStyle(color: hintColor),
                border: InputBorder.none,
              ),
              style: TextStyle(
                fontSize: 15,
                height: 1.45,
                color: textColor,
                fontFamily: 'JetBrainsMonoNerd',
              ),
              keyboardType: TextInputType.multiline,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMarkdownPreview(Color textColor) {
    if (_loadingIndex) {
      return const Center(child: CircularProgressIndicator());
    }
    final content = _contentController.text;
    if (content.trim().isEmpty) {
      return Center(
        child: Icon(
          Icons.article_outlined,
          size: 52,
          color: textColor.withValues(alpha: 0.45),
        ),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 48),
      child: Align(
        alignment: Alignment.topLeft,
        child: KnowledgeMarkdownView(
          data: content,
          knowledgeIndex: _knowledgeIndex,
          textColor: textColor,
          linkColor: Theme.of(context).colorScheme.primary,
          onWikiLink: _openWikiLink,
          onBlockReference: _openBlockReference,
          onExternalLink: _openExternalLink,
        ),
      ),
    );
  }

  Future<void> _setMode(_EditorMode mode) async {
    if (_mode == mode) return;
    setState(() => _mode = mode);
    if (mode == _EditorMode.preview) await _loadKnowledgeIndex();
  }

  Future<void> _loadKnowledgeIndex() async {
    final request = ++_indexRequest;
    if (mounted) setState(() => _loadingIndex = true);
    try {
      await _repository.initialize();
      final notes = await _repository.getAllStoredNotes();
      final draft = _draftAsNote();
      if (draft != null) {
        notes.removeWhere((note) => note.uuid == draft.uuid);
        notes.add(draft);
      }
      final index = KnowledgeIndex.build(notes);
      if (mounted && request == _indexRequest) {
        setState(() => _knowledgeIndex = index);
      }
    } finally {
      if (mounted && request == _indexRequest) {
        setState(() => _loadingIndex = false);
      }
    }
  }

  Note? _draftAsNote() {
    final title = _titleController.text.trim();
    final content = _contentController.text;
    if (_persistedNote == null && title.isEmpty && content.trim().isEmpty) {
      return null;
    }
    final now = DateTime.now();
    return (_persistedNote ??
            Note(
              uuid: '__editor-draft__',
              title: title,
              content: content,
              createdAt: now,
              modifiedAt: now,
            ))
        .copyWith(
      title: title,
      content: content,
      formatVersion: 2,
      aliases: _aliases,
      tags: _tags,
      isChecklist: false,
      checklistItems: const [],
      isTemplate: _isTemplate,
    );
  }

  void _wrapSelection(String prefix, String suffix, String placeholder) {
    final selection = _contentController.selection;
    final start =
        selection.isValid ? selection.start : _contentController.text.length;
    final end = selection.isValid ? selection.end : start;
    final selected = start == end
        ? placeholder
        : _contentController.text.substring(start, end);
    final replacement = '$prefix$selected$suffix';
    final updated =
        _contentController.text.replaceRange(start, end, replacement);
    _contentController.value = TextEditingValue(
      text: updated,
      selection: TextSelection(
        baseOffset: start + prefix.length,
        extentOffset: start + prefix.length + selected.length,
      ),
    );
    _contentFocus.requestFocus();
  }

  void _prefixSelectedLines(String prefix) {
    final text = _contentController.text;
    final selection = _contentController.selection;
    final selectionStart = selection.isValid ? selection.start : text.length;
    final selectionEnd = selection.isValid ? selection.end : selectionStart;
    final lineStart = selectionStart == 0
        ? 0
        : text.lastIndexOf('\n', selectionStart - 1) + 1;
    final nextNewline = text.indexOf('\n', selectionEnd);
    final lineEnd = nextNewline < 0 ? text.length : nextNewline;
    final lines = text.substring(lineStart, lineEnd).split('\n');
    final replacement = lines.map((line) => '$prefix$line').join('\n');
    final updated = text.replaceRange(lineStart, lineEnd, replacement);
    _contentController.value = TextEditingValue(
      text: updated,
      selection: TextSelection(
        baseOffset: selectionStart + prefix.length,
        extentOffset: selectionEnd + prefix.length * lines.length,
      ),
    );
    _contentFocus.requestFocus();
  }

  Future<void> _insertWikiLink() async {
    await _repository.initialize();
    final notes = (await _repository.getAllStoredNotes())
        .where((note) => !note.isTemplate && note.uuid != _persistedNote?.uuid)
        .toList()
      ..sort((left, right) => left.title.compareTo(right.title));
    if (!mounted) return;
    final controller = TextEditingController();
    final selected = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final query = controller.text.trim().toLowerCase();
          final matches = notes
              .where((note) {
                return query.isEmpty ||
                    note.title.toLowerCase().contains(query) ||
                    note.aliases
                        .any((alias) => alias.toLowerCase().contains(query));
              })
              .take(8)
              .toList();
          return AlertDialog(
            title: const Text('Insert note link'),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: controller,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Note title or alias',
                      prefixIcon: Icon(Icons.search),
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => setDialogState(() {}),
                    onSubmitted: (value) {
                      if (value.trim().isNotEmpty) {
                        Navigator.pop(dialogContext, value.trim());
                      }
                    },
                  ),
                  if (matches.isNotEmpty)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 260),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: matches.length,
                        itemBuilder: (context, index) {
                          final note = matches[index];
                          return ListTile(
                            dense: true,
                            leading: const Icon(Icons.description_outlined),
                            title: Text(note.title),
                            subtitle: note.aliases.isEmpty
                                ? null
                                : Text(note.aliases.join(', ')),
                            onTap: () =>
                                Navigator.pop(dialogContext, note.title),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: controller.text.trim().isEmpty
                    ? null
                    : () =>
                        Navigator.pop(dialogContext, controller.text.trim()),
                child: const Text('Insert'),
              ),
            ],
          );
        },
      ),
    );
    controller.dispose();
    if (selected == null || !mounted) return;
    _insertAtSelection('[[$selected]]');
  }

  Future<void> _insertBlockAnchor() async {
    final controller = TextEditingController(
      text: const Uuid().v4().replaceAll('-', '').substring(0, 12),
    );
    final id = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Add block anchor'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            prefixText: '^',
            labelText: 'Block ID',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              if (RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$').hasMatch(value)) {
                Navigator.pop(dialogContext, value);
              }
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (id == null || !mounted) return;
    final selection = _contentController.selection;
    final cursor =
        selection.isValid ? selection.end : _contentController.text.length;
    final lineEnd = _contentController.text.indexOf('\n', cursor);
    final offset = lineEnd < 0 ? _contentController.text.length : lineEnd;
    final prefix =
        offset > 0 && _contentController.text[offset - 1].trim().isEmpty
            ? ''
            : ' ';
    final updated = _contentController.text.replaceRange(
      offset,
      offset,
      '$prefix^$id',
    );
    _contentController.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(
        offset: offset + prefix.length + id.length + 1,
      ),
    );
    _contentFocus.requestFocus();
  }

  void _insertAtSelection(String value) {
    final selection = _contentController.selection;
    final start =
        selection.isValid ? selection.start : _contentController.text.length;
    final end = selection.isValid ? selection.end : start;
    final updated = _contentController.text.replaceRange(start, end, value);
    _contentController.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: start + value.length),
    );
    _contentFocus.requestFocus();
  }

  Future<void> _openWikiLink(String target, String? heading) async {
    await _loadKnowledgeIndex();
    final resolution = _knowledgeIndex?.resolveLink(target);
    if (!mounted || resolution == null) return;
    if (resolution.status == LinkResolutionStatus.resolved) {
      await _openLinkedNote(resolution.note!, heading: heading);
      return;
    }
    if (resolution.status == LinkResolutionStatus.ambiguous) {
      final selected = await showModalBottomSheet<Note>(
        context: context,
        showDragHandle: true,
        builder: (sheetContext) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final note in resolution.matches)
                ListTile(
                  leading: const Icon(Icons.description_outlined),
                  title: Text(note.title),
                  subtitle: Text(note.uuid),
                  onTap: () => Navigator.pop(sheetContext, note),
                ),
            ],
          ),
        ),
      );
      if (selected != null && mounted) {
        await _openLinkedNote(selected, heading: heading);
      }
      return;
    }

    final create = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Create linked note?'),
        content: Text('No note matches "$target".'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (create != true || !mounted) return;
    await _repository.initialize();
    final initialContent = heading == null || heading.trim().isEmpty
        ? '# $target\n'
        : '# $target\n\n## ${heading.trim()}\n';
    final note = await _repository.createNote(
      title: target.substring(0, target.length.clamp(0, 500)),
      content: initialContent,
      formatVersion: 2,
    );
    _invalidateNoteProviders();
    ForegroundSyncService.scheduleSync(
      reason: 'linked note created',
      debounce: const Duration(seconds: 2),
    );
    if (mounted) await _openLinkedNote(note, heading: heading);
  }

  Future<void> _openBlockReference(String id) async {
    await _loadKnowledgeIndex();
    final matches = _knowledgeIndex?.resolveBlock(id) ?? const [];
    if (!mounted) return;
    if (matches.length == 1) {
      await _openLinkedNote(
        matches.single.note,
        contentOffset: matches.single.block.startOffset,
      );
      return;
    }
    final message = matches.isEmpty
        ? 'No block uses ^$id'
        : 'More than one block uses ^$id';
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openExternalLink(String href) async {
    final uri = Uri.tryParse(href);
    if (uri == null ||
        !const {'http', 'https', 'mailto'}.contains(uri.scheme)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unsupported link')),
        );
      }
      return;
    }
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open link')),
      );
    }
  }

  Future<void> _openLinkedNote(
    Note note, {
    String? heading,
    int? contentOffset,
  }) async {
    if (note.uuid == _persistedNote?.uuid) {
      if (heading == null && contentOffset == null) {
        await _showOutline();
      } else {
        _jumpToContentTarget(
          heading: heading,
          contentOffset: contentOffset,
        );
      }
      return;
    }
    final saved = await _queueLatestSave(showError: true);
    if (!saved || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NoteEditorDialog(
          note: note,
          initialHeading: heading,
          initialContentOffset: contentOffset,
        ),
      ),
    );
    _invalidateNoteProviders();
    await _loadKnowledgeIndex();
  }

  void _jumpToContentTarget({String? heading, int? contentOffset}) {
    var offset = contentOffset;
    if (heading != null && heading.trim().isNotEmpty) {
      final value = heading.trim().replaceFirst(RegExp(r'^#'), '');
      final anchor = KnowledgeNoteParser.slugifyHeading(value);
      final matches = _parser.parse(_contentController.text).headings.where(
            (candidate) =>
                candidate.anchor.toLowerCase() == anchor ||
                candidate.title.toLowerCase() == value.toLowerCase(),
          );
      if (matches.isNotEmpty) offset = matches.first.headingStart;
    }
    if (offset == null) return;
    final bounded = offset.clamp(0, _contentController.text.length);
    if (_mode != _EditorMode.edit) setState(() => _mode = _EditorMode.edit);
    _contentController.selection = TextSelection.collapsed(offset: bounded);
    _contentFocus.requestFocus();
  }

  Future<void> _showOutline() async {
    final headings = _parser.parse(_contentController.text).headings;
    if (!mounted) return;
    if (headings.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This note has no Markdown headings')),
      );
      return;
    }
    final selected = await showModalBottomSheet<NoteHeading>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: headings.length,
          itemBuilder: (context, index) {
            final heading = headings[index];
            return ListTile(
              contentPadding: EdgeInsets.only(
                left: 16.0 + (heading.level - 1) * 16,
                right: 16,
              ),
              leading: Text('H${heading.level}'),
              title: Text(heading.title),
              subtitle: Text('#${heading.anchor}'),
              onTap: () => Navigator.pop(sheetContext, heading),
            );
          },
        ),
      ),
    );
    if (selected == null || !mounted) return;
    setState(() => _mode = _EditorMode.edit);
    _contentController.selection = TextSelection.collapsed(
      offset: selected.headingStart,
    );
    _contentFocus.requestFocus();
  }

  Future<void> _showBacklinks() async {
    final note = _persistedNote;
    if (note == null) return;
    await _loadKnowledgeIndex();
    final backlinks = _knowledgeIndex?.backlinksFor(note.uuid) ?? const [];
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.7,
          ),
          child: backlinks.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(32),
                  child: Text('No backlinks or mentions'),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: backlinks.length,
                  itemBuilder: (context, index) {
                    final backlink = backlinks[index];
                    return ListTile(
                      leading: Icon(
                        backlink.isUnlinkedMention
                            ? Icons.format_quote
                            : Icons.link,
                      ),
                      title: Text(backlink.source.title),
                      subtitle: Text(
                        backlink.isUnlinkedMention
                            ? 'Unlinked mention: ${backlink.label}'
                            : backlink.heading == null
                                ? 'Links to this note'
                                : 'Links to #${backlink.heading}',
                      ),
                      onTap: () {
                        Navigator.pop(sheetContext);
                        unawaited(_openLinkedNote(backlink.source));
                      },
                    );
                  },
                ),
        ),
      ),
    );
  }

  Future<void> _handleEditorAction(_EditorAction action) async {
    switch (action) {
      case _EditorAction.aliases:
        await _editAliases();
      case _EditorAction.saveAsTemplate:
        await _saveAsTemplate();
      case _EditorAction.exportMarkdown:
        await _exportMarkdown();
      case _EditorAction.archive:
        await _archiveNote();
      case _EditorAction.delete:
        await _deleteNote();
    }
  }

  Future<void> _editAliases() async {
    final working = List<String>.from(_aliases);
    final controller = TextEditingController();
    final result = await showDialog<List<String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          void addAlias() {
            final value = controller.text.trim();
            if (value.isEmpty ||
                working.any(
                  (alias) => alias.toLowerCase() == value.toLowerCase(),
                )) {
              return;
            }
            setDialogState(() {
              working.add(value);
              controller.clear();
            });
          }

          return AlertDialog(
            title: const Text('Note aliases'),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: controller,
                    decoration: const InputDecoration(
                      labelText: 'Alias',
                      prefixIcon: Icon(Icons.alternate_email),
                      border: OutlineInputBorder(),
                    ),
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => addAlias(),
                  ),
                  if (working.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final alias in working)
                            InputChip(
                              label: Text(alias),
                              onDeleted: () =>
                                  setDialogState(() => working.remove(alias)),
                            ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              TextButton(onPressed: addAlias, child: const Text('Add')),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, working),
                child: const Text('Done'),
              ),
            ],
          );
        },
      ),
    );
    controller.dispose();
    if (result == null || !mounted) return;
    setState(() => _aliases = result);
    _markChanged();
  }

  Future<void> _addTag() async {
    final controller = TextEditingController();
    String? error;
    final tag = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Add tag'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Tag name',
              prefixIcon: const Icon(Icons.tag),
              border: const OutlineInputBorder(),
              errorText: error,
            ),
            textInputAction: TextInputAction.done,
            onChanged: (_) {
              if (error != null) setDialogState(() => error = null);
            },
            onSubmitted: (value) {
              final normalized = value.trim().replaceFirst(RegExp(r'^#'), '');
              if (normalized.isEmpty || normalized.length > 80) {
                setDialogState(
                  () => error = 'Enter a tag of up to 80 characters',
                );
              } else {
                Navigator.pop(dialogContext, normalized);
              }
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final value =
                    controller.text.trim().replaceFirst(RegExp(r'^#'), '');
                if (value.isEmpty || value.length > 80) {
                  setDialogState(
                    () => error = 'Enter a tag of up to 80 characters',
                  );
                } else {
                  Navigator.pop(dialogContext, value);
                }
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (tag == null ||
        _tags.any((existing) => existing.toLowerCase() == tag.toLowerCase()) ||
        !mounted) {
      return;
    }
    setState(() => _tags.add(tag));
    _markChanged();
  }

  Future<void> _saveAsTemplate() async {
    final saved = await _queueLatestSave(showError: true);
    if (!saved || !mounted) return;
    final controller = TextEditingController(
      text: _titleController.text.trim().isEmpty
          ? 'New template'
          : '${_titleController.text.trim()} template',
    );
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Save as template'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Template name',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              if (value.isNotEmpty) Navigator.pop(dialogContext, value);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || !mounted) return;
    await _repository.createNote(
      title: name,
      content: _contentController.text,
      formatVersion: 2,
      color: _selectedColor,
      tags: _tags,
      aliases: _aliases,
      isTemplate: true,
    );
    ref.invalidate(noteTemplatesProvider);
    ForegroundSyncService.scheduleSync(
      reason: 'note template created',
      debounce: const Duration(seconds: 2),
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Template "$name" saved')),
      );
    }
  }

  Future<void> _exportMarkdown() async {
    final saved = await _queueLatestSave(showError: true);
    final note = _persistedNote;
    if (!saved || note == null) return;
    final safeTitle = (note.title.trim().isEmpty ? 'untitled' : note.title)
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
    try {
      final exported = await const NoteFileService().saveMarkdown(
        suggestedName: '${safeTitle.isEmpty ? 'note' : safeTitle}.md',
        bytes: const NoteTransferCodec().encodeBytes(note),
      );
      if (exported && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Markdown exported')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not export Markdown: $error')),
        );
      }
    }
  }

  void _showColorPicker() {
    final brightness = Theme.of(context).brightness;
    final picker = Wrap(
      spacing: 12,
      runSpacing: 12,
      children: NoteColor.values.map((color) {
        final selected = color == _selectedColor;
        return Tooltip(
          message: _colorName(color),
          child: InkResponse(
            radius: 30,
            onTap: () {
              setState(() => _selectedColor = color);
              _markChanged();
              Navigator.pop(context);
            },
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.getColorForBrightness(brightness),
                border: Border.all(
                  color: selected
                      ? Theme.of(context).colorScheme.primary
                      : NoteColorPalette.getBorderColor(
                          color.colorIndex,
                          brightness,
                        ),
                  width: selected ? 3 : 1,
                ),
              ),
              child: selected ? const Icon(Icons.check) : null,
            ),
          ),
        );
      }).toList(),
    );
    if (MediaQuery.sizeOf(context).width >= 720) {
      showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Choose color'),
          content: SizedBox(width: 360, child: picker),
        ),
      );
    } else {
      showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (_) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
            child: picker,
          ),
        ),
      );
    }
  }

  String _colorName(NoteColor color) {
    final name = color.name;
    return '${name[0].toUpperCase()}${name.substring(1)}';
  }

  Widget _buildSaveStatus(Color textColor) {
    final style = TextButton.styleFrom(
      foregroundColor: textColor,
      disabledForegroundColor: textColor.withValues(alpha: 0.7),
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
          child: CircularProgressIndicator(strokeWidth: 2, color: textColor),
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
    return TextButton.icon(
      onPressed: null,
      style: style,
      icon: Icon(
        _persistedNote == null ? Icons.edit_note : Icons.check_circle_outline,
        size: 18,
      ),
      label: Text(_persistedNote == null ? 'Not saved yet' : 'Saved'),
    );
  }

  Future<void> _manualSave() async {
    if (_isClosing || _pendingSaveCount > 0) return;
    await _queueLatestSave(showError: true);
  }

  Future<void> _deleteNote() async {
    final note = _persistedNote;
    if (note == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(_isTemplate ? 'Delete template?' : 'Delete note?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || _isClosing) return;
    setState(() => _isClosing = true);
    _autoSaveTimer?.cancel();
    _discardPendingChanges = true;
    _hasChanges = false;
    try {
      await _saveQueue;
      await _repository.initialize();
      await _repository.deleteNote(note.uuid);
      ForegroundSyncService.scheduleSync(
        reason: _isTemplate ? 'note template deleted' : 'note deleted',
        debounce: const Duration(seconds: 1),
      );
      _invalidateNoteProviders();
      await _closeEditor();
    } catch (error) {
      _discardPendingChanges = false;
      _hasChanges = _changeRevision > _savedRevision;
      if (mounted) setState(() => _isClosing = false);
      _showSaveError(error);
    }
  }

  Future<void> _archiveNote() async {
    if (_persistedNote == null || _isClosing || _isTemplate) return;
    setState(() => _isClosing = true);
    final saved = await _queueLatestSave(showError: true);
    if (!saved) {
      if (mounted) setState(() => _isClosing = false);
      return;
    }
    try {
      _persistedNote = await _repository.updateNote(
        _persistedNote!.copyWith(isArchived: true),
      );
      ForegroundSyncService.scheduleSync(
        reason: 'note archived',
        debounce: const Duration(seconds: 1),
      );
      _hasChanges = false;
      _discardPendingChanges = true;
      _invalidateNoteProviders();
      await _closeEditor();
    } catch (error) {
      if (mounted) setState(() => _isClosing = false);
      _showSaveError(error);
    }
  }

  Future<void> _handleBack() async {
    if (_isClosing) return;
    setState(() => _isClosing = true);
    final saved = await _queueLatestSave(showError: true);
    if (!saved) {
      if (mounted) setState(() => _isClosing = false);
      return;
    }
    _discardPendingChanges = true;
    _invalidateNoteProviders();
    await _closeEditor();
  }

  Future<void> _closeEditor() async {
    if (!mounted) return;
    setState(() => _canPop = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.pop(context);
  }

  _NoteDraft _buildDraft() => _NoteDraft(
        title: _titleController.text.trim(),
        content: _contentController.text,
        color: _selectedColor,
        isPinned: _isPinned,
        tags: List<String>.from(_tags),
        aliases: List<String>.from(_aliases),
        journalDate: _journalDate,
        isTemplate: _isTemplate,
      );

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
    if (_persistedNote == null &&
        draft.title.isEmpty &&
        draft.content.trim().isEmpty) {
      _savedRevision = revision;
      _hasChanges = false;
      if (updateUi) _notifySaveStatus();
      return true;
    }

    _pendingSaveCount++;
    if (updateUi) _notifySaveStatus();
    final operation = _saveQueue.then((_) async {
      await _repository.initialize();
      final current = _persistedNote;
      if (current == null) {
        _persistedNote = await _repository.createNote(
          title: draft.title,
          content: draft.content,
          formatVersion: 2,
          color: draft.color,
          isPinned: draft.isPinned,
          tags: draft.tags,
          aliases: draft.aliases,
          journalDate: draft.journalDate,
          isTemplate: draft.isTemplate,
        );
      } else {
        _persistedNote = await _repository.updateNote(
          current.copyWith(
            title: draft.title,
            content: draft.content,
            formatVersion: 2,
            color: draft.color,
            isPinned: draft.isPinned,
            tags: draft.tags,
            aliases: draft.aliases,
            isChecklist: false,
            checklistItems: const [],
            journalDate: draft.journalDate,
            isTemplate: draft.isTemplate,
          ),
        );
      }
    });
    _saveQueue = operation.catchError((_) {});
    try {
      await operation;
      ForegroundSyncService.scheduleSync(
        reason: draft.isTemplate ? 'note template saved' : 'note saved',
        debounce: const Duration(seconds: 8),
      );
      if (revision > _savedRevision) _savedRevision = revision;
      _hasChanges = _changeRevision > _savedRevision;
      _lastSaveError = null;
      _invalidateNoteProviders();
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

  void _invalidateNoteProviders() {
    ref.invalidate(notesProvider);
    ref.invalidate(archivedNotesProvider);
    ref.invalidate(noteTemplatesProvider);
    ref.invalidate(knowledgeIndexProvider);
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
  final List<String> aliases;
  final DateTime? journalDate;
  final bool isTemplate;

  const _NoteDraft({
    required this.title,
    required this.content,
    required this.color,
    required this.isPinned,
    required this.tags,
    required this.aliases,
    required this.journalDate,
    required this.isTemplate,
  });
}

class _MarkdownToolbar extends StatelessWidget {
  final Color color;
  final VoidCallback onHeading;
  final VoidCallback onBold;
  final VoidCallback onItalic;
  final VoidCallback onCode;
  final VoidCallback onBullet;
  final VoidCallback onNumbered;
  final VoidCallback onTask;
  final VoidCallback onQuote;
  final VoidCallback onLink;
  final VoidCallback onWikiLink;
  final VoidCallback onBlockAnchor;

  const _MarkdownToolbar({
    required this.color,
    required this.onHeading,
    required this.onBold,
    required this.onItalic,
    required this.onCode,
    required this.onBullet,
    required this.onNumbered,
    required this.onTask,
    required this.onQuote,
    required this.onLink,
    required this.onWikiLink,
    required this.onBlockAnchor,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          _button(Icons.title, 'Heading', onHeading),
          _button(Icons.format_bold, 'Bold', onBold),
          _button(Icons.format_italic, 'Italic', onItalic),
          _button(Icons.code, 'Inline code', onCode),
          const VerticalDivider(indent: 8, endIndent: 8),
          _button(Icons.format_list_bulleted, 'Bullet list', onBullet),
          _button(Icons.format_list_numbered, 'Numbered list', onNumbered),
          _button(Icons.check_box_outlined, 'Task', onTask),
          _button(Icons.format_quote, 'Quote', onQuote),
          const VerticalDivider(indent: 8, endIndent: 8),
          _button(Icons.link, 'External link', onLink),
          _button(Icons.hub_outlined, 'Note link', onWikiLink),
          _button(Icons.tag, 'Block anchor', onBlockAnchor),
        ],
      ),
    );
  }

  Widget _button(IconData icon, String tooltip, VoidCallback onPressed) {
    return SizedBox(
      width: 42,
      height: 42,
      child: IconButton(
        icon: Icon(icon, size: 20, color: color),
        tooltip: tooltip,
        visualDensity: VisualDensity.compact,
        onPressed: onPressed,
      ),
    );
  }
}
