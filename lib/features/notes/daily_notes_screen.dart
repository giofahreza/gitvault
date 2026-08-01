import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/notes/note_templates.dart';
import '../../core/providers/providers.dart';
import '../../core/services/foreground_sync_service.dart';
import '../../data/models/note.dart';
import '../../data/repositories/notes_repository.dart';
import 'note_editor_screen.dart';
import 'note_template_picker.dart';

class DailyNotesScreen extends ConsumerStatefulWidget {
  const DailyNotesScreen({super.key});

  @override
  ConsumerState<DailyNotesScreen> createState() => _DailyNotesScreenState();
}

class _DailyNotesScreenState extends ConsumerState<DailyNotesScreen> {
  late DateTime _selectedDate;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _selectedDate = DateTime(now.year, now.month, now.day);
  }

  @override
  Widget build(BuildContext context) {
    final notes = ref.watch(notesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Daily notes'),
        actions: [
          TextButton.icon(
            onPressed: _opening
                ? null
                : () {
                    final now = DateTime.now();
                    setState(() {
                      _selectedDate = DateTime(now.year, now.month, now.day);
                    });
                  },
            icon: const Icon(Icons.today, size: 18),
            label: const Text('Today'),
          ),
        ],
      ),
      body: notes.when(
        data: _buildContent,
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Text('Could not load daily notes: $error'),
        ),
      ),
    );
  }

  Widget _buildContent(List<Note> notes) {
    final journals = notes.where((note) => note.journalDate != null).toList()
      ..sort((left, right) => right.journalDate!.compareTo(left.journalDate!));
    Note? selected;
    for (final note in journals) {
      if (journalDay(note.journalDate!) == journalDay(_selectedDate)) {
        selected = note;
        break;
      }
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 840;
        final calendar = _buildCalendar(selected);
        final recent = _buildRecent(journals, scrollable: wide);
        return wide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: 420, child: calendar),
                  const VerticalDivider(width: 1),
                  Expanded(child: recent),
                ],
              )
            : ListView(
                padding: const EdgeInsets.only(bottom: 32),
                children: [calendar, const Divider(), recent],
              );
      },
    );
  }

  Widget _buildCalendar(Note? selected) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CalendarDatePicker(
            initialDate: _selectedDate,
            firstDate: DateTime(2000),
            lastDate: DateTime(2200),
            onDateChanged: (date) => setState(() => _selectedDate = date),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _opening ? null : () => _openDate(selected),
              icon: Icon(selected == null ? Icons.add : Icons.open_in_new),
              label: Text(
                selected == null
                    ? 'Create ${dailyNoteTitle(_selectedDate)}'
                    : 'Open ${dailyNoteTitle(_selectedDate)}',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecent(List<Note> journals, {required bool scrollable}) {
    if (journals.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: Text('No daily notes yet')),
      );
    }
    return ListView.builder(
      shrinkWrap: !scrollable,
      physics: scrollable ? null : const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(12),
      itemCount: journals.length,
      itemBuilder: (context, index) {
        final note = journals[index];
        return ListTile(
          leading: const Icon(Icons.calendar_today_outlined),
          title: Text(note.title),
          subtitle: Text(
            note.markdownContent,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => _navigateToEditor(note),
        );
      },
    );
  }

  Future<void> _openDate(Note? existing) async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      var note = existing;
      if (note == null) {
        final seed = await showNoteTemplatePicker(
          context,
          ref,
          date: _selectedDate,
          dailyOnly: true,
        );
        if (seed == null || !mounted) return;
        final repository = ref.read(notesRepositoryProvider);
        await repository.initialize();
        final result = await repository.getOrCreateJournalNote(
          date: _selectedDate,
          title: dailyNoteTitle(_selectedDate),
          content: seed.content,
          tags: <String>{'journal', ...seed.tags}.toList(),
          aliases: seed.aliases,
          color: seed.color,
        );
        note = result.note;
        _invalidateNotes();
        ForegroundSyncService.scheduleSync(
          reason: 'daily note created',
          debounce: const Duration(seconds: 2),
        );
      }
      if (mounted) await _navigateToEditor(note);
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _navigateToEditor(Note note) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => NoteEditorDialog(note: note)),
    );
    _invalidateNotes();
  }

  void _invalidateNotes() {
    ref.invalidate(notesProvider);
    ref.invalidate(knowledgeIndexProvider);
  }
}
