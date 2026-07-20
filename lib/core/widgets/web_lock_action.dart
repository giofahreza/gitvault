import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';

class WebLockAction extends ConsumerWidget {
  final bool compactOnly;
  final bool filled;
  final double railBreakpoint;

  const WebLockAction({
    super.key,
    this.compactOnly = false,
    this.filled = false,
    this.railBreakpoint = 720,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!kIsWeb) return const SizedBox.shrink();
    if (compactOnly && MediaQuery.sizeOf(context).width >= railBreakpoint) {
      return const SizedBox.shrink();
    }

    void lock() {
      FocusManager.instance.primaryFocus?.unfocus();
      ref.read(appLockSignalProvider.notifier).state++;
    }

    final icon = const Icon(Icons.lock_outline);
    if (filled) {
      return IconButton.filledTonal(
        icon: icon,
        tooltip: 'Lock vault',
        onPressed: lock,
      );
    }

    return IconButton(
      icon: icon,
      tooltip: 'Lock vault',
      onPressed: lock,
    );
  }
}
