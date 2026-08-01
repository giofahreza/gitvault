import 'dart:typed_data';

class PickedMarkdownFile {
  final String name;
  final Uint8List bytes;

  const PickedMarkdownFile({required this.name, required this.bytes});
}
