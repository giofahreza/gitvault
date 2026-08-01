import 'dart:typed_data';

import 'note_file_types.dart';
import 'note_file_service_stub.dart'
    if (dart.library.io) 'note_file_service_io.dart'
    if (dart.library.html) 'note_file_service_web.dart' as platform;

class NoteFileService {
  const NoteFileService();

  Future<PickedMarkdownFile?> pickMarkdown() => platform.pickMarkdown();

  Future<bool> saveMarkdown({
    required String suggestedName,
    required Uint8List bytes,
  }) =>
      platform.saveMarkdown(suggestedName: suggestedName, bytes: bytes);
}
