import 'package:flutter/material.dart';

/// Requests focus on pointer-down so Flutter web text fields are ready before
/// fast desktop keyboard input starts.
class PointerFocus extends StatelessWidget {
  final FocusNode focusNode;
  final Widget child;

  const PointerFocus({
    super.key,
    required this.focusNode,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    void requestFocus() {
      if (focusNode.canRequestFocus) {
        FocusScope.of(context).requestFocus(focusNode);
      }
    }

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => requestFocus(),
      onPointerUp: (_) => requestFocus(),
      child: child,
    );
  }
}
