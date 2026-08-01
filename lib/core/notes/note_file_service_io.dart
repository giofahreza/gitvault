import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:file_selector/file_selector.dart' as selector;

import 'note_file_types.dart';

const _markdownTypes = selector.XTypeGroup(
  label: 'Markdown',
  extensions: ['md', 'markdown', 'txt'],
);

Future<PickedMarkdownFile?> pickMarkdown() async {
  if (Platform.isLinux) {
    final file = await selector.openFile(
      acceptedTypeGroups: const [_markdownTypes],
      confirmButtonText: 'Import',
    );
    if (file == null) return null;
    return PickedMarkdownFile(name: file.name, bytes: await file.readAsBytes());
  }

  final result = await FilePicker.platform.pickFiles(
    dialogTitle: 'Import Markdown note',
    type: FileType.custom,
    allowedExtensions: const ['md', 'markdown', 'txt'],
    allowMultiple: false,
    withData: true,
  );
  if (result == null) return null;
  final file = result.files.single;
  final bytes = file.bytes ??
      (file.path == null ? null : await File(file.path!).readAsBytes());
  if (bytes == null) return null;
  return PickedMarkdownFile(name: file.name, bytes: bytes);
}

Future<bool> saveMarkdown({
  required String suggestedName,
  required Uint8List bytes,
}) async {
  if (Platform.isLinux) {
    final location = await selector.getSaveLocation(
      acceptedTypeGroups: const [_markdownTypes],
      suggestedName: suggestedName,
      confirmButtonText: 'Export',
    );
    if (location == null) return false;
    await File(location.path).writeAsBytes(bytes, flush: true);
    return true;
  }

  final path = await FilePicker.platform.saveFile(
    dialogTitle: 'Export decrypted Markdown note',
    fileName: suggestedName,
    type: FileType.custom,
    allowedExtensions: const ['md'],
    lockParentWindow: true,
  );
  if (path == null) return false;
  await File(path).writeAsBytes(bytes, flush: true);
  return true;
}
