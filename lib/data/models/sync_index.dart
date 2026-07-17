import 'package:freezed_annotation/freezed_annotation.dart';

part 'sync_index.freezed.dart';
part 'sync_index.g.dart';

@freezed
class SyncIndex with _$SyncIndex {
  const factory SyncIndex({
    required DateTime lastUpdated,
    required int monotonicCounter,
    required Map<String, String> uuidToHashMap, // UUID -> filename hash
    // Keyed hashes of the plaintext payload. The whole index is encrypted, so
    // these do not reveal note or credential contents to GitHub. Older indexes
    // omit this field and simply perform one full upload to populate it.
    @Default(<String, String>{}) Map<String, String> uuidToContentHashMap,
  }) = _SyncIndex;

  factory SyncIndex.fromJson(Map<String, dynamic> json) =>
      _$SyncIndexFromJson(json);
}
