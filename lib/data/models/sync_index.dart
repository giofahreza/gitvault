import 'package:freezed_annotation/freezed_annotation.dart';

part 'sync_index.freezed.dart';
part 'sync_index.g.dart';

@freezed
class SyncIndex with _$SyncIndex {
  const factory SyncIndex({
    required DateTime lastUpdated,
    required int monotonicCounter,
    required Map<String, String> uuidToHashMap, // UUID -> filename hash
  }) = _SyncIndex;

  factory SyncIndex.fromJson(Map<String, dynamic> json) =>
      _$SyncIndexFromJson(json);
}
