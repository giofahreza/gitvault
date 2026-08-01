import 'package:flutter_test/flutter_test.dart';
import 'package:gitvault/core/notes/knowledge_index.dart';
import 'package:gitvault/core/notes/knowledge_parser.dart';
import 'package:gitvault/core/notes/note_templates.dart';
import 'package:gitvault/core/notes/note_transfer.dart';
import 'package:gitvault/data/models/note.dart';

void main() {
  const parser = KnowledgeNoteParser();

  test('parses Markdown knowledge syntax without interpreting code spans', () {
    const source = '''# Plan

- [ ] Ship Linux
- [x] Ship web

See [[Architecture#Storage|storage design]] and ((decision-1)).

Decision accepted. ^decision-1

`[[not-a-link]] ((not-a-block))`

```text
[[also-not-a-link]]
```
''';

    final result = parser.parse(source);

    expect(result.headings.single.title, 'Plan');
    expect(result.headings.single.anchor, 'plan');
    expect(result.taskCount, 2);
    expect(result.completedTaskCount, 1);
    expect(result.wikiLinks.single.target, 'Architecture');
    expect(result.wikiLinks.single.heading, 'Storage');
    expect(result.wikiLinks.single.label, 'storage design');
    expect(result.blockReferences, ['decision-1']);
    expect(result.blocks.single.id, 'decision-1');
    expect(result.blocks.single.text, 'Decision accepted.');
    expect(
      result.plainText,
      'Plan\nShip Linux\nShip web\nSee storage design and referenced block.\n'
      'Decision accepted.\n[[not-a-link]] ((not-a-block))\n'
      '[[also-not-a-link]]',
    );
  });

  test('replaces only the selected heading section', () {
    const source = '''# First
old
## Child
old child
# Second
keep
''';

    final updated = parser.replaceSection(
      source,
      heading: 'first',
      replacement: 'new body',
    );

    expect(updated, '# First\nnew body\n# Second\nkeep\n');
  });

  test('generates deterministic unique anchors for repeated headings', () {
    final headings = parser.parse('# Notes\n## Notes\n## Notes\n').headings;
    expect(headings.map((heading) => heading.anchor), [
      'notes',
      'notes-1',
      'notes-2',
    ]);
  });

  test('knowledge index resolves aliases, backlinks, mentions, and blocks', () {
    final target = _note(
      id: 'target-id',
      title: 'Architecture',
      aliases: const ['System design'],
      content: '# Storage\nDecision. ^storage-decision',
    );
    final linked = _note(
      id: 'linked',
      title: 'Plan',
      content: 'Read [[System design#Storage]].',
    );
    final mentioned = _note(
      id: 'mentioned',
      title: 'Review',
      content: 'Architecture needs another review.',
    );
    final index = KnowledgeIndex.build([target, linked, mentioned]);

    expect(index.resolveLink('System design').note?.uuid, target.uuid);
    expect(index.resolveLink('target-id').note?.uuid, target.uuid);
    final backlinks = index.backlinksFor(target.uuid);
    expect(backlinks.map((item) => item.source.uuid), ['linked', 'mentioned']);
    expect(backlinks.last.isUnlinkedMention, isTrue);
    expect(
        index.resolveBlock('storage-decision').single.note.uuid, target.uuid,);
    expect(index.graphEdges.single.sourceId, linked.uuid);
  });

  test('legacy checklist exposes canonical Markdown without mutation', () {
    final note = _note(
      id: 'legacy',
      title: 'Tasks',
      content: '',
      isChecklist: true,
      checklistItems: const [
        ChecklistItem(text: 'Open', isChecked: false),
        ChecklistItem(text: 'Done', isChecked: true),
      ],
    );

    expect(note.markdownContent, '- [ ] Open\n- [x] Done');
    expect(note.formatVersion, 1);
  });

  test('Markdown transfer round trips structured front matter', () {
    final note = _note(
      id: 'exported',
      title: 'Quoted: "title"',
      content: '# Body\n\n[[Other]]',
      aliases: const ['Alias one'],
      tags: const ['work'],
      journalDate: DateTime.utc(2026, 8, 1),
    );
    const codec = NoteTransferCodec();

    final imported = codec.decode(
      codec.encode(note),
      fallbackName: 'fallback.md',
    );

    expect(imported.title, note.title);
    expect(imported.content, note.content);
    expect(imported.aliases, note.aliases);
    expect(imported.tags, note.tags);
    expect(imported.journalDate, note.journalDate);
  });

  test('template expansion uses stable date placeholders', () {
    final expanded = expandNoteTemplate(
      '{{date}} {{year}} {{month}} {{day}}',
      DateTime.utc(2026, 8, 1, 23, 30),
    );
    expect(expanded, '2026-08-01 2026 08 01');
  });

  test('Markdown transfer accepts CRLF front matter', () {
    const codec = NoteTransferCodec();
    const source = '---\r\n'
        'title: Windows note\r\n'
        'tags:\r\n'
        '  - imported\r\n'
        '---\r\n'
        '# Body\r\n';

    final imported = codec.decode(source, fallbackName: 'fallback.md');

    expect(imported.title, 'Windows note');
    expect(imported.tags, ['imported']);
    expect(imported.content, '# Body\n');
  });
}

Note _note({
  required String id,
  required String title,
  required String content,
  List<String> aliases = const [],
  List<String> tags = const [],
  bool isChecklist = false,
  List<ChecklistItem> checklistItems = const [],
  DateTime? journalDate,
}) {
  return Note(
    uuid: id,
    title: title,
    content: content,
    aliases: aliases,
    tags: tags,
    isChecklist: isChecklist,
    checklistItems: checklistItems,
    journalDate: journalDate,
    createdAt: DateTime.utc(2026, 8, 1),
    modifiedAt: DateTime.utc(2026, 8, 1),
  );
}
