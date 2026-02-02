import 'dart:convert';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'ssh_credential.freezed.dart';
part 'ssh_credential.g.dart';

enum SshAuthType {
  password,
  publicKey,
}

@freezed
class SshCredential with _$SshCredential {
  const factory SshCredential({
    required String uuid,
    required String label,
    required String host,
    @Default(22) int port,
    required String username,
    @Default(SshAuthType.password) SshAuthType authType,
    @Default('') String password,
    @Default('') String privateKey,
    @Default('') String passphrase,
    required DateTime createdAt,
    required DateTime modifiedAt,
  }) = _SshCredential;

  factory SshCredential.fromJson(Map<String, dynamic> json) =>
      _$SshCredentialFromJson(json);
}

extension SshCredentialExtension on SshCredential {
  String toJsonString() => jsonEncode(toJson());
}
