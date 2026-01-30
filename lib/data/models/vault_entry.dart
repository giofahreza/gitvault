import 'dart:convert';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'vault_entry.freezed.dart';
part 'vault_entry.g.dart';

@freezed
class VaultEntry with _$VaultEntry {
  const factory VaultEntry({
    required String uuid,
    required String title,
    required String username,
    required String password,
    String? url,
    String? totpSecret,
    String? notes,
    required DateTime createdAt,
    required DateTime modifiedAt,
    @Default([]) List<String> tags,
  }) = _VaultEntry;

  factory VaultEntry.fromJson(Map<String, dynamic> json) =>
      _$VaultEntryFromJson(json);
}

extension VaultEntryExtension on VaultEntry {
  String toJsonString() => jsonEncode(toJson());
}
