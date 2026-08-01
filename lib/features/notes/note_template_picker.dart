import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/notes/note_templates.dart';
import '../../core/providers/providers.dart';
import '../../data/models/note.dart';

class NoteCreationSeed {
  final String title;
  final String content;
  final List<String> tags;
  final List<String> aliases;
  final NoteColor color;
  final String sourceName;

  const NoteCreationSeed({
    required this.title,
    required this.content,
    required this.tags,
    required this.aliases,
    required this.color,
    required this.sourceName,
  });

  factory NoteCreationSeed.builtIn(
    BuiltInNoteTemplate template,
    DateTime date,
  ) {
    return NoteCreationSeed(
      title: expandNoteTemplate(template.title, date),
      content: expandNoteTemplate(template.content, date),
      tags: template.tags,
      aliases: const [],
      color: NoteColor.white,
      sourceName: template.name,
    );
  }

  factory NoteCreationSeed.saved(Note template, DateTime date) {
    return NoteCreationSeed(
      title: expandNoteTemplate(template.title, date),
      content: expandNoteTemplate(template.markdownContent, date),
      tags: template.tags,
      aliases: template.aliases,
      color: template.color,
      sourceName: template.title,
    );
  }
}

Future<NoteCreationSeed?> showNoteTemplatePicker(
  BuildContext context,
  WidgetRef ref, {
  required DateTime date,
  bool dailyOnly = false,
}) async {
  final templates = await ref.read(noteTemplatesProvider.future);
  if (!context.mounted) return null;
  final builtIns = dailyOnly
      ? builtInNoteTemplates
          .where((template) => template.id == 'daily-log')
          .toList()
      : builtInNoteTemplates;

  return showModalBottomSheet<NoteCreationSeed>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.72,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Text(
                dailyOnly ? 'Daily note template' : 'Create note',
                style: Theme.of(sheetContext).textTheme.titleLarge,
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final template in builtIns)
                    ListTile(
                      leading: Icon(_templateIcon(template.id)),
                      title: Text(template.name),
                      subtitle: Text(template.description),
                      onTap: () => Navigator.pop(
                        sheetContext,
                        NoteCreationSeed.builtIn(template, date),
                      ),
                    ),
                  if (templates.isNotEmpty) ...[
                    const Divider(),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                      child: Text(
                        'SAVED TEMPLATES',
                        style: Theme.of(sheetContext).textTheme.labelSmall,
                      ),
                    ),
                    for (final template in templates)
                      ListTile(
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
                        onTap: () => Navigator.pop(
                          sheetContext,
                          NoteCreationSeed.saved(template, date),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

IconData _templateIcon(String id) {
  switch (id) {
    case 'daily-log':
      return Icons.today_outlined;
    case 'meeting':
      return Icons.groups_outlined;
    case 'project':
      return Icons.account_tree_outlined;
    default:
      return Icons.note_add_outlined;
  }
}
