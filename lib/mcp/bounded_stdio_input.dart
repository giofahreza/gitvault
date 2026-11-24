import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const maximumStdioFrameBytes = 1024 * 1024;

/// Buffer only bounded, complete frames before giving them to the SDK parser.
/// On overflow, a fixed malformed frame produces its normal redacted parse
/// error. Discard the rest of that line so a valid prefix cannot execute.
Stream<List<int>> boundStdioFrames(Stream<List<int>> input,
    {int maximumBytes = maximumStdioFrameBytes}) async* {
  if (maximumBytes < 1) throw ArgumentError.value(maximumBytes);
  final pending = BytesBuilder(copy: false);
  var discarding = false;
  await for (final chunk in input) {
    var start = 0;
    while (start < chunk.length) {
      final newline = chunk.indexOf(10, start);
      final end = newline < 0 ? chunk.length : newline;
      if (!discarding) {
        if (pending.length + end - start > maximumBytes) {
          pending.clear();
          discarding = true;
          yield const [123, 10];
        } else {
          pending.add(chunk.sublist(start, end));
        }
      }
      if (newline < 0) break;
      if (!discarding) {
        yield [...pending.takeBytes(), 10];
      }
      discarding = false;
      start = newline + 1;
    }
  }
  // Match the SDK's EOF policy: an incomplete final frame is not a request.
}

/// Preserve the SDK's stdio transport, including its malformed-message and
/// cancellation handling, while limiting its asynchronous input buffer.
class BoundedStdioInput extends Stream<List<int>> implements Stdin {
  final Stdin source;
  BoundedStdioInput(this.source);

  @override
  StreamSubscription<List<int>> listen(void Function(List<int>)? onData,
          {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
      boundStdioFrames(source).listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  @override
  bool get echoMode => source.echoMode;
  @override
  set echoMode(bool value) => source.echoMode = value;
  @override
  bool get echoNewlineMode => source.echoNewlineMode;
  @override
  set echoNewlineMode(bool value) => source.echoNewlineMode = value;
  @override
  bool get lineMode => source.lineMode;
  @override
  set lineMode(bool value) => source.lineMode = value;
  @override
  bool get supportsAnsiEscapes => source.supportsAnsiEscapes;
  @override
  bool get hasTerminal => source.hasTerminal;
  @override
  int readByteSync() => source.readByteSync();
  @override
  String? readLineSync(
          {Encoding encoding = systemEncoding, bool retainNewlines = false}) =>
      source.readLineSync(encoding: encoding, retainNewlines: retainNewlines);
}
