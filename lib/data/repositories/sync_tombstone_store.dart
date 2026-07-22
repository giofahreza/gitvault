import 'dart:convert';

import 'package:hive/hive.dart';

/// Persists local deletion timestamps so a pull cannot resurrect an item that
/// was deleted before the delete has been pushed to remote storage.
class SyncTombstoneStore {
  static const String boxName = 'sync_metadata';
  static const String _deletedItemsKey = 'deleted_items_v1';

  static Future<Map<String, String>> loadDeletedAtMap({
    Box<String>? box,
  }) async {
    final metadataBox = box ?? await Hive.openBox<String>(boxName);
    return _decodeDeletedAtMap(metadataBox.get(_deletedItemsKey));
  }

  static Future<void> recordDeletion(
    String uuid, {
    DateTime? deletedAt,
    Box<String>? box,
  }) async {
    final metadataBox = box ?? await Hive.openBox<String>(boxName);
    final deletedAtMap = _decodeDeletedAtMap(metadataBox.get(_deletedItemsKey));
    final nextDeletedAt = (deletedAt ?? DateTime.now()).toUtc();
    final existingDeletedAt = parseDeletedAt(deletedAtMap[uuid]);

    if (existingDeletedAt != null &&
        existingDeletedAt.isAfter(nextDeletedAt)) {
      return;
    }

    deletedAtMap[uuid] = nextDeletedAt.toIso8601String();
    await metadataBox.put(_deletedItemsKey, jsonEncode(deletedAtMap));
  }

  static Future<void> clearDeletion(
    String uuid, {
    Box<String>? box,
  }) async {
    final metadataBox = box ?? await Hive.openBox<String>(boxName);
    final deletedAtMap = _decodeDeletedAtMap(metadataBox.get(_deletedItemsKey));
    if (!deletedAtMap.containsKey(uuid)) return;

    deletedAtMap.remove(uuid);
    await metadataBox.put(_deletedItemsKey, jsonEncode(deletedAtMap));
  }

  static DateTime? parseDeletedAt(String? value) {
    if (value == null || value.isEmpty) return null;
    return DateTime.tryParse(value)?.toUtc();
  }

  static Map<String, String> _decodeDeletedAtMap(String? value) {
    if (value == null || value.isEmpty) return <String, String>{};

    try {
      final decoded = jsonDecode(value) as Map<String, dynamic>;
      return decoded.map(
        (key, value) => MapEntry(key, value.toString()),
      );
    } catch (_) {
      return <String, String>{};
    }
  }
}
