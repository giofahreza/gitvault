import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/notes/knowledge_index.dart';
import '../../core/providers/providers.dart';
import '../../data/models/note.dart';
import '../../utils/pointer_focus.dart';
import 'note_editor_screen.dart';

class KnowledgeGraphScreen extends ConsumerStatefulWidget {
  const KnowledgeGraphScreen({super.key});

  @override
  ConsumerState<KnowledgeGraphScreen> createState() =>
      _KnowledgeGraphScreenState();
}

class _KnowledgeGraphScreenState extends ConsumerState<KnowledgeGraphScreen> {
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  bool _showCompactSearch = false;
  int _compactSearchGeneration = 0;

  @override
  void dispose() {
    _searchController.clear();
    _searchFocusNode.unfocus();
    TextInput.finishAutofillContext(shouldSave: false);
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final index = ref.watch(knowledgeIndexProvider);
    final compact = MediaQuery.sizeOf(context).width < 600;
    final compactSearchOpen =
        compact && (_showCompactSearch || _searchController.text.isNotEmpty);
    return Scaffold(
      appBar: AppBar(
        excludeHeaderSemantics: compactSearchOpen,
        title: compactSearchOpen
            ? _buildSearchField()
            : const Text('Knowledge graph'),
        actions: compact
            ? [
                IconButton(
                  tooltip: compactSearchOpen ? 'Close search' : 'Find note',
                  icon: Icon(
                    compactSearchOpen ? Icons.close : Icons.search,
                  ),
                  onPressed: () {
                    if (compactSearchOpen) {
                      _closeCompactSearch();
                    } else {
                      unawaited(_openCompactSearch());
                    }
                  },
                ),
              ]
            : [
                SizedBox(
                  width: math.min(280, MediaQuery.sizeOf(context).width * 0.42),
                  child: _buildSearchField(includeSearchIcon: true),
                ),
              ],
      ),
      body: index.when(
        data: (index) => ValueListenableBuilder<TextEditingValue>(
          valueListenable: _searchController,
          builder: (context, value, _) => _buildGraph(index, value.text),
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) =>
            Center(child: Text('Could not build graph: $error')),
      ),
    );
  }

  Widget _buildSearchField({bool includeSearchIcon = false}) {
    return PointerFocus(
      focusNode: _searchFocusNode,
      child: Semantics(
        label: 'Find note',
        child: TextField(
          key: includeSearchIcon
              ? const ValueKey('knowledge_graph_desktop_search')
              : ValueKey(
                  'knowledge_graph_compact_search_$_compactSearchGeneration',
                ),
          controller: _searchController,
          focusNode: _searchFocusNode,
          autofocus: true,
          decoration: InputDecoration(
            hintText: 'Find note',
            prefixIcon: includeSearchIcon ? const Icon(Icons.search) : null,
            border: InputBorder.none,
          ),
        ),
      ),
    );
  }

  Future<void> _openCompactSearch() async {
    FocusManager.instance.primaryFocus?.unfocus();
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    setState(() {
      _compactSearchGeneration++;
      _showCompactSearch = true;
    });
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    _requestSearchFocus();
  }

  void _requestSearchFocus() {
    if (!mounted || !_showCompactSearch) return;
    FocusScope.of(context).requestFocus(_searchFocusNode);
  }

  void _closeCompactSearch() {
    _searchController.clear();
    setState(() {
      _showCompactSearch = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _searchFocusNode.unfocus();
      FocusManager.instance.primaryFocus?.unfocus();
      TextInput.finishAutofillContext(shouldSave: false);
      setState(() => _showCompactSearch = false);
    });
  }

  Widget _buildGraph(KnowledgeIndex index, String searchQuery) {
    final query = searchQuery.trim().toLowerCase();
    final notes = index.notesById.values.where((note) {
      return query.isEmpty ||
          note.title.toLowerCase().contains(query) ||
          note.aliases.any((alias) => alias.toLowerCase().contains(query));
    }).toList()
      ..sort((left, right) => left.title.compareTo(right.title));

    return LayoutBuilder(
      key: const ValueKey('knowledge_graph_results'),
      builder: (context, constraints) {
        if (notes.isEmpty) {
          return Center(
            child: Text(
              query.isEmpty ? 'No linked notes yet' : 'No matching notes',
            ),
          );
        }

        const nodeWidth = 168.0;
        const nodeHeight = 52.0;
        const horizontalGap = 78.0;
        const verticalGap = 70.0;
        const minimumPadding = 24.0;
        final viewportWidth = constraints.maxWidth;
        final viewportHeight = constraints.maxHeight;
        final preferredColumns = math.max(1, math.sqrt(notes.length).ceil());
        final fittingColumns = math.max(
          1,
          ((viewportWidth - minimumPadding * 2 + horizontalGap) /
                  (nodeWidth + horizontalGap))
              .floor(),
        );
        final columns = math.min(preferredColumns, fittingColumns);
        final rows = (notes.length / columns).ceil();
        final contentWidth =
            columns * nodeWidth + math.max(0, columns - 1) * horizontalGap;
        final horizontalPadding =
            math.max(minimumPadding, (viewportWidth - contentWidth) / 2);
        final canvasWidth = math.max(
          viewportWidth,
          contentWidth + horizontalPadding * 2,
        );
        final canvasHeight = math.max(
          viewportHeight,
          rows * nodeHeight +
              math.max(0, rows - 1) * verticalGap +
              minimumPadding * 2,
        );
        final positions = <String, Offset>{};
        for (var index = 0; index < notes.length; index++) {
          final column = index % columns;
          final row = index ~/ columns;
          positions[notes[index].uuid] = Offset(
            horizontalPadding + column * (nodeWidth + horizontalGap),
            minimumPadding + row * (nodeHeight + verticalGap),
          );
        }
        final visibleIds = positions.keys.toSet();
        final edges = index.graphEdges
            .where(
              (edge) =>
                  visibleIds.contains(edge.sourceId) &&
                  visibleIds.contains(edge.targetId),
            )
            .toList();

        return InteractiveViewer(
          constrained: false,
          boundaryMargin: const EdgeInsets.all(160),
          minScale: 0.35,
          maxScale: 2.5,
          child: SizedBox(
            width: canvasWidth,
            height: canvasHeight,
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _GraphEdgePainter(
                      edges: edges,
                      positions: positions,
                      nodeSize: const Size(nodeWidth, nodeHeight),
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
                ),
                for (final note in notes)
                  Positioned(
                    left: positions[note.uuid]!.dx,
                    top: positions[note.uuid]!.dy,
                    width: nodeWidth,
                    height: nodeHeight,
                    child: _GraphNode(
                      note: note,
                      connected: edges.any(
                        (edge) =>
                            edge.sourceId == note.uuid ||
                            edge.targetId == note.uuid,
                      ),
                      onTap: () => _openNote(note),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _openNote(Note note) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => NoteEditorDialog(note: note)),
    );
    ref.invalidate(notesProvider);
    ref.invalidate(knowledgeIndexProvider);
  }
}

class _GraphNode extends StatelessWidget {
  final Note note;
  final bool connected;
  final VoidCallback onTap;

  const _GraphNode({
    required this.note,
    required this.connected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: note.aliases.isEmpty
          ? note.title
          : '${note.title}\n${note.aliases.join(', ')}',
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          backgroundColor: note.isArchived
              ? colorScheme.surfaceContainerHighest
              : colorScheme.surface,
          side: BorderSide(
            color: connected ? colorScheme.primary : colorScheme.outline,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
          ),
        ),
        onPressed: onTap,
        icon: Icon(
          note.journalDate == null
              ? Icons.description_outlined
              : Icons.calendar_today_outlined,
          size: 17,
        ),
        label: Text(
          note.title.trim().isEmpty ? 'Untitled' : note.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}

class _GraphEdgePainter extends CustomPainter {
  final List<KnowledgeGraphEdge> edges;
  final Map<String, Offset> positions;
  final Size nodeSize;
  final Color color;

  const _GraphEdgePainter({
    required this.edges,
    required this.positions,
    required this.nodeSize,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    final centerOffset = Offset(nodeSize.width / 2, nodeSize.height / 2);
    for (final edge in edges) {
      final source = positions[edge.sourceId];
      final target = positions[edge.targetId];
      if (source == null || target == null) continue;
      canvas.drawLine(source + centerOffset, target + centerOffset, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _GraphEdgePainter oldDelegate) {
    return oldDelegate.edges != edges ||
        oldDelegate.positions != positions ||
        oldDelegate.color != color;
  }
}
