import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitvault/core/crypto/crypto_manager.dart';
import 'package:gitvault/core/crypto/key_storage.dart';
import 'package:gitvault/core/services/github_service.dart';
import 'package:gitvault/data/repositories/notes_repository.dart';
import 'package:gitvault/data/repositories/sync_engine.dart';
import 'package:gitvault/data/repositories/ssh_repository.dart';
import 'package:gitvault/data/repositories/vault_repository.dart';
import 'package:gitvault/utils/constants.dart';
import 'package:hive/hive.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('com.giofahreza.gitvault/ime'),
    (_) async => null,
  );

  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'gitvault_device_recovery_test_',
    );
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    await _resetHiveBoxes();
  });

  tearDownAll(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('late trusted-device approval is treated as expired', () async {
    final harness = await _createHarness({
      'devices': const <Map<String, dynamic>>[],
      'pendingDeviceApprovals': [
        _approval(
          status: 'approved',
          expiresAt: DateTime.now().subtract(const Duration(seconds: 10)),
          respondedAt: DateTime.now().subtract(const Duration(seconds: 5)),
        ),
      ],
    });

    final status = await SyncEngine.getDeviceApprovalStatus(
      keyStorage: harness.keyStorage,
      cryptoManager: harness.cryptoManager,
      githubService: harness.githubService,
      rootKey: harness.rootKey,
      approvalId: 'approval-1',
    );

    expect(status.isExpired, isTrue);
  });

  test('timely approval remains valid when requester polls after expiry',
      () async {
    final harness = await _createHarness({
      'devices': const <Map<String, dynamic>>[],
      'pendingDeviceApprovals': [
        _approval(
          status: 'approved',
          expiresAt: DateTime.now().subtract(const Duration(seconds: 5)),
          respondedAt: DateTime.now().subtract(const Duration(seconds: 10)),
        ),
      ],
    });

    final status = await SyncEngine.getDeviceApprovalStatus(
      keyStorage: harness.keyStorage,
      cryptoManager: harness.cryptoManager,
      githubService: harness.githubService,
      rootKey: harness.rootKey,
      approvalId: 'approval-1',
    );

    expect(status.isApproved, isTrue);
  });

  test('expired pending approval cannot be approved with false success',
      () async {
    final harness = await _createHarness({
      'devices': const <Map<String, dynamic>>[],
      'pendingDeviceApprovals': [
        _approval(
          status: 'pending',
          expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
        ),
      ],
    });

    await expectLater(
      SyncEngine.respondToDeviceApproval(
        keyStorage: harness.keyStorage,
        cryptoManager: harness.cryptoManager,
        githubService: harness.githubService,
        approvalId: 'approval-1',
        approved: true,
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('expired'),
        ),
      ),
    );

    final registry = await _decryptRegistry(harness);
    final approvals = registry['pendingDeviceApprovals'] as List<dynamic>;
    expect((approvals.single as Map<String, dynamic>)['status'], 'expired');
  });

  test('approved recovery cannot complete when response was too late',
      () async {
    final harness = await _createHarness({
      'devices': const <Map<String, dynamic>>[],
      'pendingDeviceApprovals': [
        _approval(
          status: 'approved',
          expiresAt: DateTime.now().subtract(const Duration(seconds: 10)),
          respondedAt: DateTime.now().subtract(const Duration(seconds: 5)),
        ),
      ],
    });

    await expectLater(
      SyncEngine.completeApprovedRecovery(
        keyStorage: harness.keyStorage,
        cryptoManager: harness.cryptoManager,
        githubService: harness.githubService,
        rootKey: harness.rootKey,
        approvalId: 'approval-1',
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('not approved within 30 seconds'),
        ),
      ),
    );
  });

  test('original setup device is not marked as unverified remote device',
      () async {
    final now = DateTime.now().toIso8601String();
    final harness = await _createHarness({
      'devices': [
        {
          'deviceId': 'original-device',
          'name': 'Original Laptop',
          'lastSeen': now,
          'addedAt': now,
          'registrationMethod': SyncEngine.deviceRegistrationMethodSetup,
        },
        {
          'deviceId': 'trusted-device',
          'name': 'Trusted Laptop',
          'lastSeen': now,
          'addedAt': now,
          'registrationMethod': SyncEngine.deviceRegistrationMethodLink,
        },
      ],
      'pendingDeviceApprovals': const <Map<String, dynamic>>[],
    });

    final registry = await SyncEngine.refreshDeviceRegistry(
      keyStorage: harness.keyStorage,
      cryptoManager: harness.cryptoManager,
      githubService: harness.githubService,
      uploadIfNeeded: true,
    );
    final devices = registry!['devices'] as List<dynamic>;
    final original = devices
        .cast<Map<String, dynamic>>()
        .singleWhere((device) => device['deviceId'] == 'original-device');

    expect(original.containsKey('firstSeenByDeviceId'), isFalse);
    expect(harness.githubService.uploadCount, 0);
  });

  test('recovery restore pulls remote vault before any local push', () async {
    final cryptoManager = CryptoManager();
    final rootKey = cryptoManager.generateRandomKey();
    final githubService = _MemoryGitHubService({});

    final setupKeyStorage = KeyStorage();
    await setupKeyStorage.initialize();
    await setupKeyStorage.storeRootKey(rootKey);
    await setupKeyStorage.storeDeviceId('setup-device');
    await setupKeyStorage.storeLocalDeviceName('Setup Browser');
    await setupKeyStorage.storeDeviceRegistrationMethod(
      SyncEngine.deviceRegistrationMethodSetup,
    );

    final setupVault = VaultRepository(
      cryptoManager: cryptoManager,
      keyStorage: setupKeyStorage,
    );
    final setupNotes = NotesRepository(
      cryptoManager: cryptoManager,
      keyStorage: setupKeyStorage,
    );
    final setupSsh = SshRepository(
      cryptoManager: cryptoManager,
      keyStorage: setupKeyStorage,
    );
    final setupEngine = SyncEngine(
      vaultRepository: setupVault,
      notesRepository: setupNotes,
      sshRepository: setupSsh,
      githubService: githubService,
      cryptoManager: cryptoManager,
      keyStorage: setupKeyStorage,
    );
    await setupEngine.initialize();
    await setupVault.createEntry(
      title: 'Example Gmail',
      username: 'alice@example.com',
      password: 'correct horse battery staple',
    );
    final setupResult = await setupEngine.sync();

    expect(setupResult.pushed, greaterThan(0));
    expect(githubService.files.containsKey(Constants.indexFile), isTrue);

    final uploadCountBeforeRestore = githubService.uploadCount;
    await _resetHiveBoxes();

    final recoveryKeyStorage = KeyStorage();
    await recoveryKeyStorage.initialize();
    await recoveryKeyStorage.storeRootKey(rootKey);
    await recoveryKeyStorage.storeDeviceId('recovered-device');
    await recoveryKeyStorage.storeLocalDeviceName('Recovered Browser');
    await recoveryKeyStorage.storeDeviceRegistrationMethod(
      SyncEngine.deviceRegistrationMethodRecoveryTokenRotated,
    );

    final recoveryVault = VaultRepository(
      cryptoManager: cryptoManager,
      keyStorage: recoveryKeyStorage,
    );
    final recoveryNotes = NotesRepository(
      cryptoManager: cryptoManager,
      keyStorage: recoveryKeyStorage,
    );
    final recoverySsh = SshRepository(
      cryptoManager: cryptoManager,
      keyStorage: recoveryKeyStorage,
    );
    final recoveryEngine = SyncEngine(
      vaultRepository: recoveryVault,
      notesRepository: recoveryNotes,
      sshRepository: recoverySsh,
      githubService: githubService,
      cryptoManager: cryptoManager,
      keyStorage: recoveryKeyStorage,
    );
    await recoveryEngine.initialize();

    final restoreResult = await recoveryEngine.restoreFromGitHub();
    final restoredEntries = await recoveryVault.getAllEntries();
    final restoreUploadPaths = githubService.uploadedPaths
        .skip(uploadCountBeforeRestore)
        .where((path) =>
            path == Constants.indexFile ||
            path.startsWith('${Constants.dataFolder}/'))
        .toList();

    expect(restoreResult.pulled, 1);
    expect(restoreResult.pushed, 0);
    expect(restoredEntries, hasLength(1));
    expect(restoredEntries.single.title, 'Example Gmail');
    expect(restoreUploadPaths, isEmpty);
  });
}

Map<String, dynamic> _approval({
  required String status,
  required DateTime expiresAt,
  DateTime? respondedAt,
}) {
  final approval = <String, dynamic>{
    'approvalId': 'approval-1',
    'deviceId': 'new-device',
    'deviceName': 'New Browser',
    'requestType': 'recovery',
    'status': status,
    'requestedAt': DateTime.now()
        .subtract(SyncEngine.pendingDeviceApprovalLifetime)
        .toIso8601String(),
    'expiresAt': expiresAt.toIso8601String(),
  };
  if (respondedAt != null) {
    approval['respondedAt'] = respondedAt.toIso8601String();
    approval['respondedByDeviceId'] = 'trusted-device';
    approval['respondedByName'] = 'Trusted Laptop';
  }
  return approval;
}

Future<_Harness> _createHarness(Map<String, dynamic> registry) async {
  final cryptoManager = CryptoManager();
  final keyStorage = KeyStorage();
  await keyStorage.initialize();
  final rootKey = cryptoManager.generateRandomKey();
  await keyStorage.storeRootKey(rootKey);
  await keyStorage.storeDeviceId('trusted-device');
  await keyStorage.storeLocalDeviceName('Trusted Laptop');

  final githubService = _MemoryGitHubService({
    Constants.trustedDevicesFile: await _encryptRegistry(
      registry,
      cryptoManager,
      rootKey,
    ),
  });

  return _Harness(
    keyStorage: keyStorage,
    cryptoManager: cryptoManager,
    githubService: githubService,
    rootKey: rootKey,
  );
}

Future<Uint8List> _encryptRegistry(
  Map<String, dynamic> registry,
  CryptoManager cryptoManager,
  Uint8List rootKey,
) async {
  final jsonBytes = utf8.encode(jsonEncode(registry));
  final paddedBytes =
      cryptoManager.addRandomPadding(Uint8List.fromList(jsonBytes));
  final encryptedBox = await cryptoManager.encryptXChaCha20(
    data: paddedBytes,
    key: rootKey,
  );
  return encryptedBox.toBytes();
}

Future<Map<String, dynamic>> _decryptRegistry(_Harness harness) async {
  final registryBytes =
      harness.githubService.files[Constants.trustedDevicesFile]!;
  final encryptedBox = EncryptedBox.fromBytes(registryBytes);
  final decryptedPadded = await harness.cryptoManager.decryptXChaCha20(
    box: encryptedBox,
    key: harness.rootKey,
  );
  final decryptedBytes =
      harness.cryptoManager.removeRandomPadding(decryptedPadded);
  return jsonDecode(utf8.decode(decryptedBytes)) as Map<String, dynamic>;
}

class _Harness {
  final KeyStorage keyStorage;
  final CryptoManager cryptoManager;
  final _MemoryGitHubService githubService;
  final Uint8List rootKey;

  _Harness({
    required this.keyStorage,
    required this.cryptoManager,
    required this.githubService,
    required this.rootKey,
  });
}

class _MemoryGitHubService extends GitHubService {
  final Map<String, Uint8List> files;
  final List<String> uploadedPaths = [];
  var uploadCount = 0;

  _MemoryGitHubService(this.files)
      : super(
          accessToken: 'test-token',
          repoOwner: 'test-owner',
          repoName: 'test-repo',
        );

  @override
  Future<bool> verifyRepository() async => true;

  @override
  Future<Uint8List?> downloadFile(String path) async => files[path];

  @override
  Future<String> uploadFile({
    required String path,
    required Uint8List content,
    String commitMessage = 'Update entry',
    bool isRetry = false,
  }) async {
    uploadCount++;
    uploadedPaths.add(path);
    files[path] = content;
    return 'test-commit';
  }

  @override
  void dispose() {}
}

Future<void> _resetHiveBoxes() async {
  await Hive.close();
  for (final boxName in const [
    'secure_keys',
    'vault_entries',
    'notes',
    'ssh_credentials',
    'sync_metadata',
    'background_sync_settings',
  ]) {
    await Hive.deleteBoxFromDisk(boxName);
  }
}
