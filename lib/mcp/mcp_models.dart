import 'dart:convert';

enum McpClientTransport {
  streamableHttp,
  stdio;

  String get label => switch (this) {
        McpClientTransport.streamableHttp => 'Streamable HTTP',
        McpClientTransport.stdio => 'stdio',
      };
}

enum McpPermission {
  readMetadata,
  readContent,
  search,
  create,
  append,
  edit,
  archive,
  delete,
  includeArchived;

  bool get isWrite => switch (this) {
        McpPermission.create ||
        McpPermission.append ||
        McpPermission.edit ||
        McpPermission.archive ||
        McpPermission.delete =>
          true,
        _ => false,
      };

  String get label => switch (this) {
        McpPermission.readMetadata => 'Read note metadata',
        McpPermission.readContent => 'Read note content',
        McpPermission.search => 'Search notes',
        McpPermission.create => 'Create notes',
        McpPermission.append => 'Append to notes',
        McpPermission.edit => 'Edit notes',
        McpPermission.archive => 'Archive notes',
        McpPermission.delete => 'Delete notes',
        McpPermission.includeArchived => 'Include archived notes',
      };
}

enum McpWritePolicy {
  askEveryTime,
  allowWhileUnlocked;

  String get label => switch (this) {
        McpWritePolicy.askEveryTime => 'Ask every time',
        McpWritePolicy.allowWhileUnlocked => 'Allow while unlocked',
      };
}

class McpClientRegistration {
  final String id;
  final String displayName;
  final McpClientTransport transport;
  final Set<McpPermission> permissions;
  final Set<String> allowedTags;
  final Set<String> deniedTags;
  final McpWritePolicy writePolicy;
  final Set<McpPermission> approvalExemptPermissions;
  final String tokenVerifier;
  final DateTime createdAt;
  final DateTime? lastUsedAt;
  final DateTime? revokedAt;

  const McpClientRegistration({
    required this.id,
    required this.displayName,
    required this.transport,
    required this.permissions,
    required this.allowedTags,
    required this.deniedTags,
    required this.writePolicy,
    this.approvalExemptPermissions = const {},
    required this.tokenVerifier,
    required this.createdAt,
    this.lastUsedAt,
    this.revokedAt,
  });

  bool get isActive => revokedAt == null;

  McpClientRegistration copyWith({
    String? displayName,
    McpClientTransport? transport,
    Set<McpPermission>? permissions,
    Set<String>? allowedTags,
    Set<String>? deniedTags,
    McpWritePolicy? writePolicy,
    Set<McpPermission>? approvalExemptPermissions,
    String? tokenVerifier,
    DateTime? lastUsedAt,
    DateTime? revokedAt,
    bool clearLastUsedAt = false,
    bool clearRevokedAt = false,
  }) {
    return McpClientRegistration(
      id: id,
      displayName: displayName ?? this.displayName,
      transport: transport ?? this.transport,
      permissions: permissions ?? this.permissions,
      allowedTags: allowedTags ?? this.allowedTags,
      deniedTags: deniedTags ?? this.deniedTags,
      writePolicy: writePolicy ?? this.writePolicy,
      approvalExemptPermissions:
          approvalExemptPermissions ?? this.approvalExemptPermissions,
      tokenVerifier: tokenVerifier ?? this.tokenVerifier,
      createdAt: createdAt,
      lastUsedAt: clearLastUsedAt ? null : lastUsedAt ?? this.lastUsedAt,
      revokedAt: clearRevokedAt ? null : revokedAt ?? this.revokedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'displayName': displayName,
        'transport': transport.name,
        'permissions':
            permissions.map((permission) => permission.name).toList(),
        'allowedTags': allowedTags.toList(),
        'deniedTags': deniedTags.toList(),
        'writePolicy': writePolicy.name,
        'approvalExemptPermissions': approvalExemptPermissions
            .map((permission) => permission.name)
            .toList(),
        'tokenVerifier': tokenVerifier,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'lastUsedAt': lastUsedAt?.toUtc().toIso8601String(),
        'revokedAt': revokedAt?.toUtc().toIso8601String(),
      };

  factory McpClientRegistration.fromJson(Map<String, dynamic> json) {
    final permissionNames =
        (json['permissions'] as List<dynamic>? ?? const <dynamic>[])
            .whereType<String>()
            .toSet();
    final approvalExemptNames =
        (json['approvalExemptPermissions'] as List<dynamic>? ??
                const <dynamic>[])
            .whereType<String>()
            .toSet();
    return McpClientRegistration(
      id: json['id'] as String,
      displayName: json['displayName'] as String? ?? 'AI App',
      transport: McpClientTransport.values.firstWhere(
        (value) => value.name == json['transport'],
        orElse: () => McpClientTransport.stdio,
      ),
      permissions: McpPermission.values
          .where((permission) => permissionNames.contains(permission.name))
          .toSet(),
      allowedTags: _stringSet(json['allowedTags']),
      deniedTags: _stringSet(json['deniedTags']),
      writePolicy: McpWritePolicy.values.firstWhere(
        (value) => value.name == json['writePolicy'],
        orElse: () => McpWritePolicy.askEveryTime,
      ),
      approvalExemptPermissions: McpPermission.values
          .where((permission) => approvalExemptNames.contains(permission.name))
          .toSet(),
      tokenVerifier: json['tokenVerifier'] as String? ?? '',
      createdAt: _date(json['createdAt']) ?? DateTime.now().toUtc(),
      lastUsedAt: _date(json['lastUsedAt']),
      revokedAt: _date(json['revokedAt']),
    );
  }
}

class McpIssuedCredential {
  final McpClientRegistration client;
  final String token;

  const McpIssuedCredential({
    required this.client,
    required this.token,
  });
}

enum McpActivityResult {
  allowed,
  denied,
  conflict,
  failed,
}

class McpActivityRecord {
  final String id;
  final DateTime timestamp;
  final String clientId;
  final String clientName;
  final String action;
  final String? noteId;
  final McpActivityResult result;
  final bool approvalRequested;
  final String? errorCode;

  const McpActivityRecord({
    required this.id,
    required this.timestamp,
    required this.clientId,
    required this.clientName,
    required this.action,
    required this.result,
    required this.approvalRequested,
    this.noteId,
    this.errorCode,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'timestamp': timestamp.toUtc().toIso8601String(),
        'clientId': clientId,
        'clientName': clientName,
        'action': action,
        'noteId': noteId,
        'result': result.name,
        'approvalRequested': approvalRequested,
        'errorCode': errorCode,
      };

  factory McpActivityRecord.fromJson(Map<String, dynamic> json) {
    return McpActivityRecord(
      id: json['id'] as String,
      timestamp: _date(json['timestamp']) ?? DateTime.now().toUtc(),
      clientId: json['clientId'] as String? ?? '',
      clientName: json['clientName'] as String? ?? 'Unknown app',
      action: json['action'] as String? ?? 'unknown',
      noteId: json['noteId'] as String?,
      result: McpActivityResult.values.firstWhere(
        (value) => value.name == json['result'],
        orElse: () => McpActivityResult.failed,
      ),
      approvalRequested: json['approvalRequested'] as bool? ?? false,
      errorCode: json['errorCode'] as String?,
    );
  }
}

enum McpApprovalDecision {
  allowOnce,
  allowAlways,
  deny,
  timeout,
  cancelled,
}

class McpApprovalRequest {
  final String id;
  final String clientId;
  final String clientName;
  final McpPermission permission;
  final String action;
  final String? noteId;
  final String? noteTitle;
  final String summary;
  final String? before;
  final String? after;
  final DateTime createdAt;
  final DateTime expiresAt;

  const McpApprovalRequest({
    required this.id,
    required this.clientId,
    required this.clientName,
    required this.permission,
    required this.action,
    required this.summary,
    required this.createdAt,
    required this.expiresAt,
    this.noteId,
    this.noteTitle,
    this.before,
    this.after,
  });
}

class McpOperationException implements Exception {
  final String code;
  final String message;
  final Map<String, dynamic>? data;

  const McpOperationException(this.code, this.message, {this.data});

  Map<String, dynamic> toJson() => {
        'code': code,
        'message': message,
        if (data != null) 'data': data,
      };

  @override
  String toString() => '$code: $message';
}

String encodeMcpJson(Map<String, dynamic> value) => jsonEncode(value);

Set<String> _stringSet(Object? value) {
  return (value as List<dynamic>? ?? const <dynamic>[])
      .whereType<String>()
      .map((item) => item.trim().toLowerCase())
      .where((item) => item.isNotEmpty)
      .toSet();
}

DateTime? _date(Object? value) {
  if (value is! String || value.isEmpty) return null;
  return DateTime.tryParse(value)?.toUtc();
}
