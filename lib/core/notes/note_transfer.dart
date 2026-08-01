import 'dart:convert';
import 'dart:typed_data';

import 'package:yaml/yaml.dart';

import '../../data/models/note.dart';

class ImportedMarkdownNote {
  final String title;
  final String content;
  final List<String> aliases;
  final List<String> tags;
  final NoteColor color;
  final bool isPinned;
  final DateTime? journalDate;

  const ImportedMarkdownNote({
    required this.title,
    required this.content,
    required this.aliases,
    required this.tags,
    required this.color,
    required this.isPinned,
    this.journalDate,
  });
}

class NoteTransferCodec {
  static const maximumImportBytes = 512 * 1024;

  const NoteTransferCodec();

  String encode(Note note) {
    final metadata = <String, dynamic>{
      'gitvault_format': 1,
      'source_id': note.uuid,
      'title': note.title,
      'aliases': note.aliases,
      'tags': note.tags,
      'color': note.color.name,
      'pinned': note.isPinned,
      if (note.journalDate != null)
        'journal_date': note.journalDate!.toUtc().toIso8601String(),
      'created_at': note.createdAt.toUtc().toIso8601String(),
      'modified_at': note.modifiedAt.toUtc().toIso8601String(),
    };
    return '---\n${jsonEncode(metadata)}\n---\n${note.markdownContent}';
  }

  Uint8List encodeBytes(Note note) =>
      Uint8List.fromList(utf8.encode(encode(note)));

  ImportedMarkdownNote decodeBytes(
    Uint8List bytes, {
    required String fallbackName,
  }) {
    if (bytes.length > maximumImportBytes) {
      throw const NoteTransferException('file_too_large');
    }
    return decode(utf8.decode(bytes), fallbackName: fallbackName);
  }

  ImportedMarkdownNote decode(
    String source, {
    required String fallbackName,
  }) {
    var content = source;
    Map<String, dynamic> metadata = const {};
    final normalized = source.replaceAll('\r\n', '\n');
    if (normalized.startsWith('---\n')) {
      final end = normalized.indexOf('\n---\n', 4);
      if (end >= 0) {
        final frontMatter = normalized.substring(4, end);
        try {
          final decoded = loadYaml(frontMatter);
          final value = _normalizeYaml(decoded);
          if (value is Map<String, dynamic>) metadata = value;
          content = normalized.substring(end + 5);
        } on YamlException {
          throw const NoteTransferException('invalid_front_matter');
        }
      }
    }

    final fallbackTitle = fallbackName
        .replaceFirst(RegExp(r'\.md$', caseSensitive: false), '')
        .trim();
    final title = _string(metadata['title'])?.trim() ?? fallbackTitle;
    if (title.length > 500 || content.length > 256 * 1024) {
      throw const NoteTransferException('note_too_large');
    }
    final aliases = _strings(metadata['aliases']);
    final tags = _strings(metadata['tags']);
    if (aliases.length > 50 || tags.length > 50) {
      throw const NoteTransferException('too_many_metadata_values');
    }

    final colorName = _string(metadata['color'])?.toLowerCase();
    final color = NoteColor.values.firstWhere(
      (candidate) => candidate.name == colorName,
      orElse: () => NoteColor.white,
    );
    final journalDate = DateTime.tryParse(
      _string(metadata['journal_date']) ?? '',
    );

    return ImportedMarkdownNote(
      title: title,
      content: content,
      aliases: aliases,
      tags: tags,
      color: color,
      isPinned: metadata['pinned'] == true,
      journalDate: journalDate,
    );
  }

  dynamic _normalizeYaml(dynamic value) {
    if (value is YamlMap || value is Map) {
      return <String, dynamic>{
        for (final entry in (value as Map).entries)
          entry.key.toString(): _normalizeYaml(entry.value),
      };
    }
    if (value is YamlList || value is List) {
      return (value as List).map(_normalizeYaml).toList();
    }
    return value;
  }

  String? _string(dynamic value) => value is String ? value : null;

  List<String> _strings(dynamic value) {
    if (value is! List) return const [];
    return value
        .whereType<String>()
        .map((item) => item.trim().replaceFirst(RegExp(r'^#'), ''))
        .where((item) => item.isNotEmpty && item.length <= 80)
        .toSet()
        .toList();
  }
}

class NoteTransferException implements Exception {
  final String code;

  const NoteTransferException(this.code);

  @override
  String toString() => 'NoteTransferException($code)';
}
