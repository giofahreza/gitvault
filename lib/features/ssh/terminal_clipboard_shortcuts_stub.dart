import 'package:flutter/widgets.dart';
import 'terminal_clipboard_shortcuts.dart';

KeyEventResult handleTerminalClipboardShortcutsImpl({
  required KeyEvent event,
  required bool hasSelection,
  required TerminalPasteCallback onPaste,
  required TerminalCopySelectionCallback onCopySelection,
}) {
  return KeyEventResult.ignored;
}
