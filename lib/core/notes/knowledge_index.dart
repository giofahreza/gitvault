import '../../data/models/note.dart';
import 'knowledge_parser.dart';

enum LinkResolutionStatus { resolved, missing, ambiguous }

class LinkResolution {
  final String query;
  final LinkResolutionStatus status;
  final List<Note> matches;

  const LinkResolution({
    required this.query,
    required this.status,
    required this.matches,
  });

  Note? get note =>
      status == LinkResolutionStatus.resolved ? matches.single : null;
}

class NoteBacklink {
  final Note source;
  final String label;
  final String? heading;
  final bool isUnlinkedMention;

  const NoteBacklink({
    required this.source,
    required this.label,
    this.heading,
    this.isUnlinkedMention = false,
  });
}

class NoteBlockLocation {
  final Note note;
  final NoteBlock block;

  const NoteBlockLocation({required this.note, required this.block});
}

class KnowledgeGraphEdge {
  final String sourceId;
  final String targetId;

  const KnowledgeGraphEdge({
    required this.sourceId,
    required this.targetId,
  });

  String get key => '$sourceId:$targetId';
}

class KnowledgeIndex {
  final Map<String, Note> notesById;
  final Map<String, ParsedKnowledgeNote> parsedById;
  final Map<String, List<NoteBacklink>> _backlinksByTarget;
  final Map<String, List<NoteBlockLocation>> _blocksById;
  final List<KnowledgeGraphEdge> graphEdges;

  const KnowledgeIndex._({
    required this.notesById,
    required this.parsedById,
    required Map<String, List<NoteBacklink>> backlinksByTarget,
    required Map<String, List<NoteBlockLocation>> blocksById,
    required this.graphEdges,
  })  : _backlinksByTarget = backlinksByTarget,
        _blocksById = blocksById;

  factory KnowledgeIndex.build(
    Iterable<Note> sourceNotes, {
    KnowledgeNoteParser parser = const KnowledgeNoteParser(),
  }) {
    final notes = <String, Note>{};
    final parsed = <String, ParsedKnowledgeNote>{};
    final blocks = <String, List<NoteBlockLocation>>{};

    for (final note in sourceNotes.where((note) => !note.isTemplate)) {
      notes[note.uuid] = note;
      final parsedNote = parser.parse(note.markdownContent);
      parsed[note.uuid] = parsedNote;
      for (final block in parsedNote.blocks) {
        blocks.putIfAbsent(block.id, () => []).add(
              NoteBlockLocation(note: note, block: block),
            );
      }
    }

    final partial = KnowledgeIndex._(
      notesById: Map.unmodifiable(notes),
      parsedById: Map.unmodifiable(parsed),
      backlinksByTarget: const {},
      blocksById: blocks,
      graphEdges: const [],
    );
    final backlinks = <String, List<NoteBacklink>>{};
    final edges = <String, KnowledgeGraphEdge>{};

    for (final source in notes.values) {
      final sourceParsed = parsed[source.uuid]!;
      for (final link in sourceParsed.wikiLinks) {
        final resolution = partial.resolveLink(link.target);
        final target = resolution.note;
        if (target == null || target.uuid == source.uuid) continue;
        backlinks.putIfAbsent(target.uuid, () => []).add(
              NoteBacklink(
                source: source,
                label: link.label,
                heading: link.heading,
              ),
            );
        final edge = KnowledgeGraphEdge(
          sourceId: source.uuid,
          targetId: target.uuid,
        );
        edges[edge.key] = edge;
      }
    }

    return KnowledgeIndex._(
      notesById: Map.unmodifiable(notes),
      parsedById: Map.unmodifiable(parsed),
      backlinksByTarget: Map.unmodifiable(
        backlinks.map(
          (key, value) => MapEntry(
            key,
            List<NoteBacklink>.unmodifiable(value),
          ),
        ),
      ),
      blocksById: Map.unmodifiable(
        blocks.map(
          (key, value) => MapEntry(
            key,
            List<NoteBlockLocation>.unmodifiable(value),
          ),
        ),
      ),
      graphEdges: List<KnowledgeGraphEdge>.unmodifiable(edges.values),
    );
  }

  LinkResolution resolveLink(String rawQuery) {
    final query = _linkTitle(rawQuery);
    if (query.isEmpty) {
      return LinkResolution(
        query: rawQuery,
        status: LinkResolutionStatus.missing,
        matches: const [],
      );
    }

    final byId = notesById[query];
    if (byId != null) {
      return LinkResolution(
        query: rawQuery,
        status: LinkResolutionStatus.resolved,
        matches: [byId],
      );
    }

    final normalized = _normalize(query);
    final titleMatches = notesById.values
        .where((note) => _normalize(note.title) == normalized)
        .toList();
    final matches = titleMatches.isNotEmpty
        ? titleMatches
        : notesById.values
            .where(
              (note) => note.aliases.any(
                (alias) => _normalize(alias) == normalized,
              ),
            )
            .toList();

    return LinkResolution(
      query: rawQuery,
      status: matches.isEmpty
          ? LinkResolutionStatus.missing
          : matches.length == 1
              ? LinkResolutionStatus.resolved
              : LinkResolutionStatus.ambiguous,
      matches: List.unmodifiable(matches),
    );
  }

  List<NoteBacklink> backlinksFor(
    String noteId, {
    bool includeUnlinkedMentions = true,
  }) {
    final linked = List<NoteBacklink>.from(
      _backlinksByTarget[noteId] ?? const [],
    );
    if (!includeUnlinkedMentions) return linked;
    final target = notesById[noteId];
    if (target == null) return linked;
    final linkedSourceIds = linked.map((item) => item.source.uuid).toSet();
    final terms = <String>{target.title, ...target.aliases}
        .map((term) => term.trim())
        .where((term) => term.length >= 3)
        .toList();
    if (terms.isEmpty) return linked;

    for (final source in notesById.values) {
      if (source.uuid == noteId || linkedSourceIds.contains(source.uuid)) {
        continue;
      }
      final plainText = parsedById[source.uuid]?.plainText ?? '';
      final mention = terms.cast<String?>().firstWhere(
            (term) => _containsPhrase(plainText, term!),
            orElse: () => null,
          );
      if (mention != null) {
        linked.add(
          NoteBacklink(
            source: source,
            label: mention,
            isUnlinkedMention: true,
          ),
        );
      }
    }
    return linked;
  }

  List<NoteBlockLocation> resolveBlock(String blockId) =>
      List.unmodifiable(_blocksById[blockId] ?? const []);

  static String _linkTitle(String value) {
    var result = value.trim();
    final heading = result.indexOf('#');
    if (heading >= 0) result = result.substring(0, heading).trim();
    if (result.toLowerCase().endsWith('.md')) {
      result = result.substring(0, result.length - 3);
    }
    final slash = result.lastIndexOf('/');
    if (slash >= 0) result = result.substring(slash + 1);
    return result.trim();
  }

  static String _normalize(String value) =>
      value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  static bool _containsPhrase(String content, String phrase) {
    final escaped = RegExp.escape(phrase.trim());
    if (escaped.isEmpty) return false;
    return RegExp(
      '(^|[^a-z0-9])$escaped(\$|[^a-z0-9])',
      caseSensitive: false,
    ).hasMatch(content);
  }
}
