import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitvault/mcp/bounded_stdio_input.dart';

void main() {
  test(
      'MCP-GAP-011 frame limit accepts exact bytes and discards oversized prefixes',
      () async {
    final result = await boundStdioFrames(
            Stream.fromIterable([
              utf8.encode('1234\n12345\n12'),
              utf8.encode('345678\nOK\r\nTAIL'),
            ]),
            maximumBytes: 4)
        .toList();
    expect(
        result.map(utf8.decode).toList(), ['1234\n', '{\n', '{\n', 'OK\r\n']);
  });
  test(
      'MCP-GAP-011 oversized partial input rejects before newline and recovers',
      () async {
    final input = StreamController<List<int>>();
    final output = <List<int>>[];
    final rejected = Completer<void>();
    final subscription =
        boundStdioFrames(input.stream, maximumBytes: 8).listen((frame) {
      output.add(frame);
      if (!rejected.isCompleted) rejected.complete();
    });
    input.add(List.filled(9, 32));
    await rejected.future.timeout(const Duration(seconds: 1));
    expect(output, [
      [123, 10]
    ]);
    final finished = subscription.asFuture<void>();
    input.add(utf8.encode('discard me\n{}\n'));
    await input.close();
    await finished;
    expect(output, [
      [123, 10],
      [123, 125, 10]
    ]);
  });
  test('MCP-GAP-011 100 deterministic random chunk boundaries preserve frames',
      () async {
    final wire = utf8.encode('${jsonEncode({'text': '🔐\n雪'})}\n{}\n\r\n');
    for (var seed = 0; seed < 100; seed++) {
      final random = Random(seed);
      final chunks = <List<int>>[];
      for (var offset = 0; offset < wire.length;) {
        final end = min(wire.length, offset + random.nextInt(9) + 1);
        chunks.add(wire.sublist(offset, end));
        offset = end;
      }
      final frames =
          await boundStdioFrames(Stream.fromIterable(chunks)).toList();
      expect(frames.expand((frame) => frame), wire, reason: 'Seed $seed');
    }
  });
}
