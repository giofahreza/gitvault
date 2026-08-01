import 'dart:typed_data';

import 'note_file_types.dart';

Future<PickedMarkdownFile?> pickMarkdown() {
  throw UnsupportedError('Markdown files are unavailable on this platform.');
}

Future<bool> saveMarkdown({
  required String suggestedName,
  required Uint8List bytes,
}) {
  throw UnsupportedError('Markdown files are unavailable on this platform.');
}
