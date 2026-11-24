import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:gitvault/core/crypto/crypto_manager.dart';
import 'package:gitvault/core/services/github_service.dart';
import 'package:gitvault/data/repositories/sync_engine.dart';
import 'package:gitvault/utils/constants.dart';

import 'memory_registry_storage.dart';

/// A shared encrypted remote with independent device storage. Hooks model
/// another remote writer, rather than bypassing the production CAS checks.
class RegistryFixture {
  final crypto = CryptoManager();
  late final Uint8List root = crypto.generateRandomKey();
  late final remote = FixtureGitHubService();
  late Map<String, dynamic> initial;

  Future<void> seed(Map<String, dynamic> registry) async {
    initial = jsonDecode(jsonEncode(registry)) as Map<String, dynamic>;
    remote.bytes = await encrypt(registry);
  }

  Future<Uint8List> encrypt(Map<String, dynamic> registry) async =>
      (await crypto.encryptXChaCha20(
        data: crypto.addRandomPadding(
          Uint8List.fromList(utf8.encode(jsonEncode(registry))),
        ),
        key: root,
      ))
          .toBytes();

  Future<Map<String, dynamic>> decode([Uint8List? bytes]) async {
    final plain = await crypto.decryptXChaCha20(
      box: EncryptedBox.fromBytes(bytes ?? remote.bytes!),
      key: root,
    );
    return jsonDecode(utf8.decode(crypto.removeRandomPadding(plain)))
        as Map<String, dynamic>;
  }

  Future<void> edit(void Function(Map<String, dynamic>) change) async {
    final registry = await decode();
    change(registry);
    remote.bytes = await encrypt(registry);
  }

  Future<MemoryRegistryStorage> device(
    String id, {
    String method = 'setup',
    String token = 'token-canary',
  }) async {
    final storage = MemoryRegistryStorage();
    await storage.storeDeviceId(id);
    await storage.storeLocalDeviceName('Name $id');
    await storage.storeRootKey(root);
    await storage.storeDeviceRegistrationMethod(method);
    await storage.storeGitHubCredentials(
      token: token,
      repoOwner: 'fixture-owner',
      repoName: 'fixture-repo',
    );
    return storage;
  }

  Future<Map<String, dynamic>?> refresh(
    MemoryRegistryStorage storage, {
    bool upload = true,
  }) =>
      SyncEngine.refreshDeviceRegistry(
        keyStorage: storage,
        cryptoManager: crypto,
        githubService: remote,
        uploadIfNeeded: upload,
      );

  Future<String> request(MemoryRegistryStorage storage) =>
      SyncEngine.createPendingRecoveryApproval(
        keyStorage: storage,
        cryptoManager: crypto,
        githubService: remote,
        rootKey: root,
      );

  Future<void> respond(
    MemoryRegistryStorage storage,
    String id, {
    bool approved = true,
  }) =>
      SyncEngine.respondToDeviceApproval(
        keyStorage: storage,
        cryptoManager: crypto,
        githubService: remote,
        approvalId: id,
        approved: approved,
      );

  Future<void> complete(MemoryRegistryStorage storage, String id) =>
      SyncEngine.completeApprovedRecovery(
        keyStorage: storage,
        cryptoManager: crypto,
        githubService: remote,
        rootKey: root,
        approvalId: id,
      );

  Future<DeviceApprovalStatus> status(
    MemoryRegistryStorage storage,
    String id,
  ) =>
      SyncEngine.getDeviceApprovalStatus(
        keyStorage: storage,
        cryptoManager: crypto,
        githubService: remote,
        rootKey: root,
        approvalId: id,
      );

  Future<void> recognize(MemoryRegistryStorage storage, String target) =>
      SyncEngine.recognizeDeviceRegistration(
        keyStorage: storage,
        cryptoManager: crypto,
        githubService: remote,
        deviceId: target,
      );

  Future<void> revoke(MemoryRegistryStorage storage, String target) =>
      SyncEngine.revokeTrustedDevice(
        keyStorage: storage,
        cryptoManager: crypto,
        githubService: remote,
        deviceId: target,
      );

  Future<String> invite(MemoryRegistryStorage storage) =>
      SyncEngine.createPendingDeviceInvite(
        keyStorage: storage,
        cryptoManager: crypto,
        githubService: remote,
      );
}

class FixtureGitHubService extends GitHubService {
  Uint8List? bytes;
  DateTime? serverTime;
  bool hideServerTime = false;
  Object? readError;
  Object? writeError;
  Future<void> Function()? beforeWrite;
  Future<void> Function()? beforeRead;
  bool loseNextResponse = false;
  int forcedConflicts = 0;
  int reads = 0;
  int writes = 0;
  int conflicts = 0;
  final attempts = <({Uint8List content, String? expectedSha})>[];
  final history = <Uint8List>[];
  final files = <String, Uint8List>{};
  final vaultUploads = <String>[];
  Object? downloadError;

  FixtureGitHubService()
      : super(
          accessToken: 'token-canary',
          repoOwner: 'fixture-owner',
          repoName: 'fixture-repo',
        );

  String? get sha => bytes == null ? null : sha256.convert(bytes!).toString();

  @override
  Future<RemoteFileSnapshot> readFileSnapshot(String path) async {
    reads++;
    await beforeRead?.call();
    if (readError != null) throw readError!;
    return bytes == null
        ? const RemoteFileSnapshot.missing()
        : RemoteFileSnapshot(
            bytes: Uint8List.fromList(bytes!),
            sha: sha,
            serverTime:
                hideServerTime ? null : serverTime ?? DateTime.now().toUtc(),
          );
  }

  @override
  Future<String> writeFileSnapshot({
    required String path,
    required Uint8List content,
    required String? expectedSha,
    required String commitMessage,
  }) async {
    attempts.add((
      content: Uint8List.fromList(content),
      expectedSha: expectedSha,
    ));
    final hook = beforeWrite;
    beforeWrite = null;
    await hook?.call();
    if (forcedConflicts > 0 || expectedSha != sha) {
      if (forcedConflicts > 0) forcedConflicts--;
      conflicts++;
      throw GitHubException('Conflict', statusCode: 409);
    }
    if (writeError != null) throw writeError!;
    bytes = Uint8List.fromList(content);
    writes++;
    history.add(Uint8List.fromList(content));
    if (loseNextResponse) {
      loseNextResponse = false;
      throw GitHubException('Response lost', kind: 'network');
    }
    return sha!;
  }

  @override
  Future<Uint8List?> downloadFile(String path) async {
    if (downloadError != null) throw downloadError!;
    return path == Constants.trustedDevicesFile ? bytes : files[path];
  }

  @override
  Future<String> uploadFile(
      {required String path,
      required Uint8List content,
      String commitMessage = 'Update entry',
      bool isRetry = false}) async {
    if (path == Constants.trustedDevicesFile) {
      throw StateError('Registry writes require CAS');
    }
    files[path] = Uint8List.fromList(content);
    vaultUploads.add(path);
    return sha256.convert(content).toString();
  }

  @override
  Future<bool> verifyRepository() async => true;

  @override
  void dispose() {}
}
