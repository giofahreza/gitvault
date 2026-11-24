import 'dart:typed_data';
import 'package:gitvault/core/crypto/key_storage.dart';

/// Independent device state for deterministic registry and UI tests.
class MemoryRegistryStorage extends KeyStorage {
  Uint8List? root;
  String? deviceId,
      name,
      token,
      owner,
      repo,
      method,
      invite,
      registry,
      snapshot,
      dismissed;
  @override
  Future<void> initialize() async {}
  @override
  Future<void> storeRootKey(Uint8List value) async {
    root = value;
  }

  @override
  Future<Uint8List?> getRootKey() async => root;
  @override
  Future<bool> hasRootKey() async => root != null;
  @override
  Future<void> storeDeviceId(String value) async {
    deviceId = value;
  }

  @override
  Future<String?> getDeviceId() async => deviceId;
  @override
  Future<void> storeLocalDeviceName(String value) async {
    name = value;
  }

  @override
  Future<String?> getLocalDeviceName() async => name;
  @override
  Future<void> storeGitHubCredentials({
    required String token,
    required String repoOwner,
    required String repoName,
  }) async {
    this.token = token;
    owner = repoOwner;
    repo = repoName;
  }

  @override
  Future<String?> getGitHubToken() async => token;
  @override
  Future<String?> getRepoOwner() async => owner;
  @override
  Future<String?> getRepoName() async => repo;
  @override
  Future<void> clearGitHubCredentials() async {
    token = null;
    owner = null;
    repo = null;
  }

  @override
  Future<void> storeDeviceRegistrationMethod(String value) async {
    method = value;
  }

  @override
  Future<String?> getDeviceRegistrationMethod() async => method;
  @override
  Future<String?> getPendingDeviceInviteId() async => invite;
  @override
  Future<void> storePendingDeviceInviteId(String value) async {
    invite = value;
  }

  @override
  Future<void> clearPendingDeviceInviteId() async {
    invite = null;
  }

  @override
  Future<String?> getDismissedUnverifiedDeviceIds() async => dismissed;
  @override
  Future<void> storeDismissedUnverifiedDeviceIds(String value) async {
    dismissed = value;
  }

  @override
  Future<void> storeDeviceRegistry(String value) async {
    registry = value;
  }

  @override
  Future<String?> getDeviceRegistry() async => registry;
  @override
  Future<void> storeDeviceRegistrySnapshot(String value) async {
    snapshot = value;
  }

  @override
  Future<String?> getDeviceRegistrySnapshot() async => snapshot;
}
