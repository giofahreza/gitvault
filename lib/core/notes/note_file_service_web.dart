// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import 'note_file_types.dart';

Future<PickedMarkdownFile?> pickMarkdown() async {
  final result = await FilePicker.platform.pickFiles(
    dialogTitle: 'Import Markdown note',
    type: FileType.custom,
    allowedExtensions: const ['md', 'markdown', 'txt'],
    allowMultiple: false,
    withData: true,
  );
  if (result == null || result.files.single.bytes == null) return null;
  final file = result.files.single;
  return PickedMarkdownFile(name: file.name, bytes: file.bytes!);
}

Future<bool> saveMarkdown({
  required String suggestedName,
  required Uint8List bytes,
}) async {
  final blob = html.Blob([bytes], 'text/markdown;charset=utf-8');
  final url = html.Url.createObjectUrlFromBlob(blob);
  try {
    html.AnchorElement(href: url)
      ..download = suggestedName
      ..click();
    return true;
  } finally {
    html.Url.revokeObjectUrl(url);
  }
}
