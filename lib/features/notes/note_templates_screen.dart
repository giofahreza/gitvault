import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/providers.dart';
import '../../core/services/foreground_sync_service.dart';
import '../../data/models/note.dart';
import 'note_editor_screen.dart';

class NoteTemplatesScreen extends ConsumerWidget {
  const NoteTemplatesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final templates = ref.watch(noteTemplatesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Note templates')),
      body: templates.when(
        data: (items) => items.isEmpty
            ? const Center(child: Text('No saved templates'))
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
                itemCount: items.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final template = items[index];
                  return ListTile(
                    leading: const Icon(Icons.description_outlined),
                    title: Text(
                      template.title.trim().isEmpty
                          ? 'Untitled template'
                          : template.title,
                    ),
                    subtitle: Text(
                      template.markdownContent,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => _edit(context, ref, template),
                    trailing: IconButton(
                      tooltip: 'Delete template',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => _delete(context, ref, template),
                    ),
                  );
                },
              ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Text('Could not load templates: $error'),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Add template',
        onPressed: () => _edit(context, ref, null),
        child: const Icon(Icons.add),
      ),
    );
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    Note? template,
  ) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NoteEditorDialog(
          note: template,
          templateMode: true,
        ),
      ),
    );
    ref.invalidate(noteTemplatesProvider);
    ref.invalidate(knowledgeIndexProvider);
  }

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    Note template,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete template?'),
        content: Text('Delete "${template.title}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final repository = ref.read(notesRepositoryProvider);
    await repository.initialize();
    await repository.deleteNote(template.uuid);
    ref.invalidate(noteTemplatesProvider);
    ref.invalidate(knowledgeIndexProvider);
    ForegroundSyncService.scheduleSync(
      reason: 'note template deleted',
      debounce: const Duration(seconds: 1),
    );
  }
}
