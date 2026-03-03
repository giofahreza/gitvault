import 'package:flutter/widgets.dart';
import 'terminal_clipboard_shortcuts_stub.dart'
    if (dart.library.io) 'terminal_clipboard_shortcuts_io.dart'
    if (dart.library.html) 'terminal_clipboard_shortcuts_web.dart';

typedef TerminalPasteCallback = Future<void> Function();
typedef TerminalCopySelectionCallback = void Function();

KeyEventResult handleTerminalClipboardShortcuts({
  required KeyEvent event,
  required bool hasSelection,
  required TerminalPasteCallback onPaste,
  required TerminalCopySelectionCallback onCopySelection,
}) {
  return handleTerminalClipboardShortcutsImpl(
    event: event,
    hasSelection: hasSelection,
    onPaste: onPaste,
    onCopySelection: onCopySelection,
  );
}
