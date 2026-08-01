import 'package:intl/intl.dart';

class BuiltInNoteTemplate {
  final String id;
  final String name;
  final String description;
  final String title;
  final String content;
  final List<String> tags;

  const BuiltInNoteTemplate({
    required this.id,
    required this.name,
    required this.description,
    required this.title,
    required this.content,
    this.tags = const [],
  });
}

const builtInNoteTemplates = <BuiltInNoteTemplate>[
  BuiltInNoteTemplate(
    id: 'blank',
    name: 'Blank note',
    description: 'Start with an empty Markdown document.',
    title: '',
    content: '',
  ),
  BuiltInNoteTemplate(
    id: 'daily-log',
    name: 'Daily log',
    description: 'Plan the day and record decisions as they happen.',
    title: '{{date}}',
    tags: ['journal'],
    content: '''# {{date_long}}

## Priorities

- [ ]\x20

## Log

- {{time}}\x20

## Notes
''',
  ),
  BuiltInNoteTemplate(
    id: 'meeting',
    name: 'Meeting',
    description: 'Agenda, notes, decisions, and follow-up tasks.',
    title: 'Meeting - {{date}}',
    tags: ['meeting'],
    content: '''# Meeting

**Date:** {{date_long}}

## Attendees

-\x20

## Agenda

1.\x20

## Notes

## Decisions

## Actions

- [ ]\x20
''',
  ),
  BuiltInNoteTemplate(
    id: 'project',
    name: 'Project',
    description: 'Define an outcome, milestones, references, and tasks.',
    title: 'Project - ',
    tags: ['project'],
    content: '''# Outcome

## Context

## Milestones

- [ ]\x20

## References

## Log

- {{date}} - Created
''',
  ),
];

String expandNoteTemplate(String value, DateTime date) {
  return value
      .replaceAll('{{date}}', DateFormat('yyyy-MM-dd').format(date))
      .replaceAll('{{date_long}}', DateFormat.yMMMMEEEEd().format(date))
      .replaceAll('{{time}}', DateFormat('HH:mm').format(date))
      .replaceAll('{{year}}', DateFormat('yyyy').format(date))
      .replaceAll('{{month}}', DateFormat('MM').format(date))
      .replaceAll('{{day}}', DateFormat('dd').format(date));
}

String dailyNoteTitle(DateTime date) => DateFormat('yyyy-MM-dd').format(date);
