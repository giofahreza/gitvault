import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'terminal_clipboard_shortcuts.dart';

KeyEventResult handleTerminalClipboardShortcutsImpl({
  required KeyEvent event,
  required bool hasSelection,
  required TerminalPasteCallback onPaste,
  required TerminalCopySelectionCallback onCopySelection,
}) {
  if (event is! KeyDownEvent) return KeyEventResult.ignored;

  final hasShortcutModifier = HardwareKeyboard.instance.isControlPressed ||
      HardwareKeyboard.instance.isMetaPressed;
  if (!hasShortcutModifier) return KeyEventResult.ignored;

  final key = event.logicalKey;
  if (key == LogicalKeyboardKey.keyV) {
    unawaited(onPaste());
    return KeyEventResult.handled;
  }

  if ((key == LogicalKeyboardKey.keyC || key == LogicalKeyboardKey.keyX) &&
      hasSelection) {
    onCopySelection();
    return KeyEventResult.handled;
  }

  return KeyEventResult.ignored;
}
