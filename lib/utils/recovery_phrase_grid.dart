import 'package:flutter/material.dart';

class RecoveryPhraseGrid extends StatelessWidget {
  final List<String> words;

  const RecoveryPhraseGrid({
    super.key,
    required this.words,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final viewportWidth = MediaQuery.sizeOf(context).width;
    final columns = viewportWidth >= 700
        ? 3
        : viewportWidth >= 360
            ? 2
            : 1;
    final rowCount = (words.length / columns).ceil();

    return Table(
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        for (var row = 0; row < rowCount; row++)
          TableRow(
            children: [
              for (var column = 0; column < columns; column++)
                _buildCell(
                  colorScheme,
                  index: row * columns + column,
                  column: column,
                  columns: columns,
                  includeBottomSpacing: row < rowCount - 1,
                ),
            ],
          ),
      ],
    );
  }

  Widget _buildCell(
    ColorScheme colorScheme, {
    required int index,
    required int column,
    required int columns,
    required bool includeBottomSpacing,
  }) {
    if (index >= words.length) return const SizedBox.shrink();

    return Padding(
      padding: EdgeInsets.only(
        left: column == 0 ? 0 : 4,
        right: column == columns - 1 ? 0 : 4,
        bottom: includeBottomSpacing ? 8 : 0,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: colorScheme.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colorScheme.outlineVariant),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 24,
              child: Text(
                '${index + 1}.',
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Expanded(
              child: SelectableText(
                words[index],
                maxLines: 1,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
