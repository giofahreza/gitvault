import 'package:markdown/markdown.dart' as md;

import 'knowledge_syntax.dart';

class WikiNoteLink {
  final String target;
  final String? heading;
  final String label;

  const WikiNoteLink({
    required this.target,
    required this.label,
    this.heading,
  });
}

class NoteHeading {
  final int level;
  final String title;
  final String anchor;
  final int headingStart;
  final int bodyStart;
  final int sectionEnd;

  const NoteHeading({
    required this.level,
    required this.title,
    required this.anchor,
    required this.headingStart,
    required this.bodyStart,
    required this.sectionEnd,
  });
}

class NoteBlock {
  final String id;
  final String text;
  final int startOffset;
  final int endOffset;

  const NoteBlock({
    required this.id,
    required this.text,
    required this.startOffset,
    required this.endOffset,
  });
}

class ParsedKnowledgeNote {
  final List<WikiNoteLink> wikiLinks;
  final List<String> blockReferences;
  final List<NoteHeading> headings;
  final List<NoteBlock> blocks;
  final int taskCount;
  final int completedTaskCount;
  final String plainText;

  const ParsedKnowledgeNote({
    required this.wikiLinks,
    required this.blockReferences,
    required this.headings,
    required this.blocks,
    required this.taskCount,
    required this.completedTaskCount,
    required this.plainText,
  });
}

class KnowledgeNoteParser {
  const KnowledgeNoteParser();

  ParsedKnowledgeNote parse(String source) {
    final collector = _KnowledgeAstCollector();
    final document = md.Document(
      extensionSet: md.ExtensionSet.gitHubFlavored,
      inlineSyntaxes: knowledgeInlineSyntaxes(),
    );
    final nodes = document.parse(source);
    for (final node in nodes) {
      node.accept(collector);
    }

    final scan = _scanSource(source);
    final plainText = _extractPlainText(nodes);

    return ParsedKnowledgeNote(
      wikiLinks: List.unmodifiable(collector.wikiLinks),
      blockReferences: List.unmodifiable(collector.blockReferences),
      headings: List.unmodifiable(scan.headings),
      blocks: List.unmodifiable(scan.blocks),
      taskCount: scan.taskCount,
      completedTaskCount: scan.completedTaskCount,
      plainText: plainText,
    );
  }

  String replaceSection(
    String source, {
    required String heading,
    required String replacement,
  }) {
    final parsed = parse(source);
    final normalized = _normalizeHeadingReference(heading);
    final matches = parsed.headings.where((candidate) {
      return candidate.anchor == normalized ||
          candidate.title.trim().toLowerCase() == heading.trim().toLowerCase();
    }).toList();
    if (matches.isEmpty) {
      throw const KnowledgeParseException('heading_not_found');
    }
    if (matches.length > 1) {
      throw const KnowledgeParseException('heading_ambiguous');
    }

    final section = matches.single;
    final normalizedReplacement = replacement.trimRight();
    final needsTrailingNewline =
        section.sectionEnd < source.length && normalizedReplacement.isNotEmpty;
    final nextBody = needsTrailingNewline
        ? '$normalizedReplacement\n'
        : normalizedReplacement;
    return source.replaceRange(
      section.bodyStart,
      section.sectionEnd,
      nextBody,
    );
  }

  String markdownPreview(String source, {int maximumLength = 500}) {
    final value =
        parse(source).plainText.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (value.length <= maximumLength) return value;
    return '${value.substring(0, maximumLength).trimRight()}...';
  }

  String _extractPlainText(List<md.Node> nodes) {
    final buffer = StringBuffer();
    const blockTags = <String>{
      'p',
      'h1',
      'h2',
      'h3',
      'h4',
      'h5',
      'h6',
      'li',
      'blockquote',
      'pre',
      'tr',
      'hr',
    };

    void visit(md.Node node) {
      if (node is md.Text) {
        buffer.write(node.textContent);
        return;
      }
      if (node is! md.Element) return;
      if (node.tag == blockAnchorElement) {
        return;
      }
      if (node.tag == blockReferenceElement) {
        buffer.write('referenced block');
        return;
      }
      if (node.tag == 'br') {
        buffer.writeln();
        return;
      }
      for (final child in node.children ?? const <md.Node>[]) {
        visit(child);
      }
      if (blockTags.contains(node.tag)) buffer.writeln();
    }

    for (final node in nodes) {
      visit(node);
      buffer.writeln();
    }
    return buffer
        .toString()
        .split('\n')
        .map((line) => line.replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((line) => line.isNotEmpty)
        .join('\n');
  }

  _SourceScan _scanSource(String source) {
    final sourceLines = _sourceLines(source);
    final headingDrafts = <_HeadingDraft>[];
    final blocks = <NoteBlock>[];
    var taskCount = 0;
    var completedTaskCount = 0;
    String? fenceCharacter;
    var fenceLength = 0;
    _SourceLine? previousContentLine;

    final anchorCounts = <String, int>{};
    for (final line in sourceLines) {
      final fence = RegExp(r'^ {0,3}(`{3,}|~{3,})').firstMatch(line.text);
      if (fenceCharacter != null) {
        if (fence != null &&
            fence.group(1)!.startsWith(fenceCharacter) &&
            fence.group(1)!.length >= fenceLength) {
          fenceCharacter = null;
          fenceLength = 0;
        }
        continue;
      }
      if (fence != null) {
        fenceCharacter = fence.group(1)![0];
        fenceLength = fence.group(1)!.length;
        continue;
      }

      final heading = RegExp(
        r'^ {0,3}(#{1,6})[ \t]+(.+?)[ \t]*#*[ \t]*$',
      ).firstMatch(line.text);
      if (heading != null) {
        var title = heading.group(2)!.trim();
        String? explicitAnchor;
        final explicit = RegExp(r'\s+\{#([A-Za-z0-9_-]+)\}$').firstMatch(title);
        if (explicit != null) {
          explicitAnchor = explicit.group(1)!;
          title = title.substring(0, explicit.start).trimRight();
        }
        final baseAnchor = explicitAnchor ?? slugifyHeading(title);
        final count = (anchorCounts[baseAnchor] ?? 0) + 1;
        anchorCounts[baseAnchor] = count;
        final anchor = count == 1 ? baseAnchor : '$baseAnchor-${count - 1}';
        headingDrafts.add(
          _HeadingDraft(
            level: heading.group(1)!.length,
            title: title,
            anchor: anchor,
            headingStart: line.startOffset,
            bodyStart: line.endOffset,
          ),
        );
        previousContentLine = null;
        continue;
      }

      final task = RegExp(r'^\s*[-*+]\s+\[([ xX])\]\s+').firstMatch(line.text);
      if (task != null) {
        taskCount++;
        if (task.group(1)!.toLowerCase() == 'x') completedTaskCount++;
      }

      final anchor = RegExp(
        r'(?:^|[ \t])\^([A-Za-z0-9][A-Za-z0-9_-]{0,99})[ \t]*$',
      ).firstMatch(line.text);
      if (anchor != null) {
        final id = anchor.group(1)!;
        final ownText = line.text.substring(0, anchor.start).trim();
        final sourceLine = ownText.isEmpty ? previousContentLine : line;
        final blockText = ownText.isEmpty
            ? (previousContentLine?.text.trim() ?? '')
            : ownText;
        if (sourceLine != null && blockText.isNotEmpty) {
          blocks.add(
            NoteBlock(
              id: id,
              text: blockText,
              startOffset: sourceLine.startOffset,
              endOffset: line.endOffset,
            ),
          );
        }
      }

      if (line.text.trim().isNotEmpty) {
        previousContentLine = line;
      }
    }

    final headings = <NoteHeading>[];
    for (var index = 0; index < headingDrafts.length; index++) {
      final current = headingDrafts[index];
      var sectionEnd = source.length;
      for (var next = index + 1; next < headingDrafts.length; next++) {
        if (headingDrafts[next].level <= current.level) {
          sectionEnd = headingDrafts[next].headingStart;
          break;
        }
      }
      headings.add(
        NoteHeading(
          level: current.level,
          title: current.title,
          anchor: current.anchor,
          headingStart: current.headingStart,
          bodyStart: current.bodyStart,
          sectionEnd: sectionEnd,
        ),
      );
    }

    return _SourceScan(
      headings: headings,
      blocks: blocks,
      taskCount: taskCount,
      completedTaskCount: completedTaskCount,
    );
  }

  List<_SourceLine> _sourceLines(String source) {
    if (source.isEmpty) return const [];
    final lines = <_SourceLine>[];
    var start = 0;
    while (start < source.length) {
      final newline = source.indexOf('\n', start);
      final contentEnd = newline < 0 ? source.length : newline;
      var textEnd = contentEnd;
      if (textEnd > start && source.codeUnitAt(textEnd - 1) == 0x0d) {
        textEnd--;
      }
      lines.add(
        _SourceLine(
          text: source.substring(start, textEnd),
          startOffset: start,
          endOffset: newline < 0 ? source.length : newline + 1,
        ),
      );
      if (newline < 0) break;
      start = newline + 1;
    }
    return lines;
  }

  String _normalizeHeadingReference(String value) {
    final trimmed = value.trim();
    return trimmed.startsWith('#')
        ? trimmed.substring(1).toLowerCase()
        : slugifyHeading(trimmed);
  }

  static String slugifyHeading(String value) {
    final slug = value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\s_-]'), '')
        .replaceAll(RegExp(r'[\s_]+'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
    return slug.isEmpty ? 'section' : slug;
  }
}

class KnowledgeParseException implements Exception {
  final String code;

  const KnowledgeParseException(this.code);

  @override
  String toString() => 'KnowledgeParseException($code)';
}

class _KnowledgeAstCollector implements md.NodeVisitor {
  final List<WikiNoteLink> wikiLinks = [];
  final List<String> blockReferences = [];

  @override
  bool visitElementBefore(md.Element element) {
    if (element.tag == wikiLinkElement) {
      final heading = element.attributes['heading'];
      wikiLinks.add(
        WikiNoteLink(
          target: element.attributes['target']!,
          heading: heading == null || heading.isEmpty ? null : heading,
          label: element.textContent,
        ),
      );
    } else if (element.tag == blockReferenceElement) {
      blockReferences.add(element.attributes['id']!);
    }
    return true;
  }

  @override
  void visitElementAfter(md.Element element) {}

  @override
  void visitText(md.Text text) {}
}

class _SourceLine {
  final String text;
  final int startOffset;
  final int endOffset;

  const _SourceLine({
    required this.text,
    required this.startOffset,
    required this.endOffset,
  });
}

class _HeadingDraft {
  final int level;
  final String title;
  final String anchor;
  final int headingStart;
  final int bodyStart;

  const _HeadingDraft({
    required this.level,
    required this.title,
    required this.anchor,
    required this.headingStart,
    required this.bodyStart,
  });
}

class _SourceScan {
  final List<NoteHeading> headings;
  final List<NoteBlock> blocks;
  final int taskCount;
  final int completedTaskCount;

  const _SourceScan({
    required this.headings,
    required this.blocks,
    required this.taskCount,
    required this.completedTaskCount,
  });
}
