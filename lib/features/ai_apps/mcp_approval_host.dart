import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../mcp/mcp_approval_controller.dart';
import '../../mcp/mcp_models.dart';
import '../../mcp/mcp_providers.dart';

class McpApprovalHost extends ConsumerStatefulWidget {
  final Widget child;

  const McpApprovalHost({
    super.key,
    required this.child,
  });

  @override
  ConsumerState<McpApprovalHost> createState() => _McpApprovalHostState();
}

class _McpApprovalHostState extends ConsumerState<McpApprovalHost> {
  String? _showingRequestId;
  BuildContext? _dialogContext;

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(mcpApprovalControllerProvider);
    final next = controller.nextRequest;

    if (_showingRequestId != null &&
        !controller.pending.any(
          (request) => request.id == _showingRequestId,
        )) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final dialogContext = _dialogContext;
        if (dialogContext != null && dialogContext.mounted) {
          Navigator.of(dialogContext).pop();
        }
      });
    } else if (_showingRequestId == null && next != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _showingRequestId == null) {
          _showRequest(controller, next);
        }
      });
    }

    return widget.child;
  }

  Future<void> _showRequest(
    McpApprovalController controller,
    McpApprovalRequest request,
  ) async {
    _showingRequestId = request.id;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        _dialogContext = dialogContext;
        return _McpApprovalDialog(
          request: request,
          onDecision: (decision) {
            controller.resolve(request.id, decision);
            if (dialogContext.mounted) Navigator.of(dialogContext).pop();
          },
        );
      },
    );
    _dialogContext = null;
    _showingRequestId = null;
    if (mounted) setState(() {});
  }
}

class _McpApprovalDialog extends StatelessWidget {
  static const int maximumPreviewCharacters = 20000;

  final McpApprovalRequest request;
  final ValueChanged<McpApprovalDecision> onDecision;

  const _McpApprovalDialog({
    required this.request,
    required this.onDecision,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      icon: const Icon(Icons.smart_toy_outlined),
      title: const Text('AI app request'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 620),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                request.clientName,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                request.summary,
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
              if (request.noteTitle != null) ...[
                const SizedBox(height: 16),
                _MetadataRow(label: 'Note', value: request.noteTitle!),
              ],
              const SizedBox(height: 8),
              _MetadataRow(
                label: 'Permission',
                value: request.permission.label,
              ),
              if (request.before != null || request.after != null) ...[
                const SizedBox(height: 20),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final horizontal = constraints.maxWidth >= 620 &&
                        request.before != null &&
                        request.after != null;
                    final previews = [
                      if (request.before != null)
                        _Preview(
                          title: 'Before',
                          content: _truncate(request.before!),
                        ),
                      if (request.after != null)
                        _Preview(
                          title: request.before == null ? 'Content' : 'After',
                          content: _truncate(request.after!),
                        ),
                    ];
                    if (horizontal) {
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (var index = 0;
                              index < previews.length;
                              index++) ...[
                            if (index > 0) const SizedBox(width: 12),
                            Expanded(child: previews[index]),
                          ],
                        ],
                      );
                    }
                    return Column(
                      children: [
                        for (var index = 0;
                            index < previews.length;
                            index++) ...[
                          if (index > 0) const SizedBox(height: 12),
                          previews[index],
                        ],
                      ],
                    );
                  },
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => onDecision(McpApprovalDecision.deny),
          child: const Text('Deny'),
        ),
        if (request.permission != McpPermission.delete)
          OutlinedButton(
            onPressed: () => onDecision(McpApprovalDecision.allowAlways),
            child: const Text('Always allow'),
          ),
        FilledButton(
          onPressed: () => onDecision(McpApprovalDecision.allowOnce),
          child: Text(
            request.permission == McpPermission.delete
                ? 'Delete'
                : 'Allow once',
          ),
        ),
      ],
    );
  }

  String _truncate(String value) {
    if (value.length <= maximumPreviewCharacters) return value;
    return '${value.substring(0, maximumPreviewCharacters)}\n\n[Preview truncated]';
  }
}

class _MetadataRow extends StatelessWidget {
  final String label;
  final String value;

  const _MetadataRow({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 88,
          child: Text(
            label,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(child: Text(value)),
      ],
    );
  }
}

class _Preview extends StatelessWidget {
  final String title;
  final String content;

  const _Preview({
    required this.title,
    required this.content,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            SelectableText(
              content,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
