import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/notes/knowledge_index.dart';
import '../../core/providers/providers.dart';
import '../../data/models/note.dart';
import 'note_editor_screen.dart';

class KnowledgeGraphScreen extends ConsumerStatefulWidget {
  const KnowledgeGraphScreen({super.key});

  @override
  ConsumerState<KnowledgeGraphScreen> createState() =>
      _KnowledgeGraphScreenState();
}

class _KnowledgeGraphScreenState extends ConsumerState<KnowledgeGraphScreen> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final index = ref.watch(knowledgeIndexProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Knowledge graph'),
        actions: [
          SizedBox(
            width: math.min(280, MediaQuery.sizeOf(context).width * 0.42),
            child: TextField(
              controller: _searchController,
              decoration: const InputDecoration(
                hintText: 'Find note',
                prefixIcon: Icon(Icons.search),
                border: InputBorder.none,
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
        ],
      ),
      body: index.when(
        data: _buildGraph,
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) =>
            Center(child: Text('Could not build graph: $error')),
      ),
    );
  }

  Widget _buildGraph(KnowledgeIndex index) {
    final query = _query.trim().toLowerCase();
    final notes = index.notesById.values.where((note) {
      return query.isEmpty ||
          note.title.toLowerCase().contains(query) ||
          note.aliases.any((alias) => alias.toLowerCase().contains(query));
    }).toList()
      ..sort((left, right) => left.title.compareTo(right.title));
    if (notes.isEmpty) {
      return Center(
        child:
            Text(query.isEmpty ? 'No linked notes yet' : 'No matching notes'),
      );
    }

    const nodeWidth = 168.0;
    const nodeHeight = 52.0;
    const horizontalGap = 78.0;
    const verticalGap = 70.0;
    final columns = math.max(1, math.sqrt(notes.length).ceil());
    final rows = (notes.length / columns).ceil();
    final canvasWidth = math.max(
      MediaQuery.sizeOf(context).width,
      columns * (nodeWidth + horizontalGap) + horizontalGap,
    );
    final canvasHeight = math.max(
      MediaQuery.sizeOf(context).height - 64,
      rows * (nodeHeight + verticalGap) + verticalGap,
    );
    final positions = <String, Offset>{};
    for (var index = 0; index < notes.length; index++) {
      final column = index % columns;
      final row = index ~/ columns;
      positions[notes[index].uuid] = Offset(
        horizontalGap + column * (nodeWidth + horizontalGap),
        verticalGap + row * (nodeHeight + verticalGap),
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
        label: Expanded(
          child: Text(
            note.title.trim().isEmpty ? 'Untitled' : note.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
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
