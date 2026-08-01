import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'mcp_platform.dart';
import 'mcp_providers.dart';

class McpRuntimeScope extends ConsumerStatefulWidget {
  final Widget child;

  const McpRuntimeScope({
    super.key,
    required this.child,
  });

  @override
  ConsumerState<McpRuntimeScope> createState() => _McpRuntimeScopeState();
}

class _McpRuntimeScopeState extends ConsumerState<McpRuntimeScope> {
  @override
  void initState() {
    super.initState();
    if (isDesktopPlatform) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(ref.read(mcpDesktopServerProvider).initialize());
          unawaited(ref.read(desktopLifecycleServiceProvider).initialize());
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
