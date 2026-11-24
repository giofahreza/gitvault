import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:gitvault/core/crypto/crypto_manager.dart';
import 'package:gitvault/core/crypto/key_storage.dart';
import 'package:gitvault/core/services/github_service.dart';
import 'package:gitvault/data/repositories/notes_repository.dart';
import 'package:gitvault/data/repositories/sync_engine.dart';
import 'package:gitvault/data/repositories/device_registry_store.dart';
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

  test('recognition rebases a concurrent approval instead of losing it',
      () async {
    final harness = await _createHarness({
      'devices': [
        {'deviceId': 'phone-device', 'registrationMethod': 'sync'},
      ],
      'pendingDeviceApprovals': [
        _approval(
          status: 'pending',
          expiresAt: DateTime.now().add(const Duration(seconds: 30)),
        ),
      ],
    });
    harness.githubService.beforeWrite = () async {
      final registry = await _decryptRegistry(harness);
      final request =
          (registry['pendingDeviceApprovals'] as List).single as Map;
      request['status'] = 'approved';
      request['respondedAt'] = DateTime.now().toIso8601String();
      request['respondedByDeviceId'] = 'other-trusted-device';
      harness.githubService.files[Constants.trustedDevicesFile] =
          await _encryptRegistry(
        registry,
        harness.cryptoManager,
        harness.rootKey,
      );
    };

    await SyncEngine.recognizeDeviceRegistration(
      keyStorage: harness.keyStorage,
      cryptoManager: harness.cryptoManager,
      githubService: harness.githubService,
      deviceId: 'phone-device',
    );

    final registry = await _decryptRegistry(harness);
    expect(
      ((registry['pendingDeviceApprovals'] as List).single as Map)['status'],
      'approved',
    );
    expect(
      ((registry['devices'] as List).single as Map)['registrationMethod'],
      'recognized',
    );
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

  test('linked device consumes invite and keeps link registration', () async {
    final cryptoManager = CryptoManager();
    final rootKey = cryptoManager.generateRandomKey();
    final now = DateTime.now();
    final harness = await _createHarnessWithRootKey(
      rootKey: rootKey,
      deviceId: 'phone-device',
      deviceName: 'Phone',
      cryptoManager: cryptoManager,
      registry: {
        'devices': [
          {
            'deviceId': 'trusted-device',
            'name': 'Trusted Laptop',
            'lastSeen': now.toIso8601String(),
            'addedAt': now.toIso8601String(),
            'registrationMethod': SyncEngine.deviceRegistrationMethodSetup,
          },
        ],
        'pendingDeviceInvites': [
          {
            'inviteId': 'invite-1',
            'createdAt': now.toIso8601String(),
            'expiresAt': now
                .add(SyncEngine.pendingDeviceInviteLifetime)
                .toIso8601String(),
            'createdByDeviceId': 'trusted-device',
            'createdByName': 'Trusted Laptop',
          },
        ],
      },
    );
    await harness.keyStorage.storeDeviceRegistrationMethod(
      SyncEngine.deviceRegistrationMethodLink,
    );
    await harness.keyStorage.storePendingDeviceInviteId('invite-1');

    final firstRegistry = await SyncEngine.refreshDeviceRegistry(
      keyStorage: harness.keyStorage,
      cryptoManager: harness.cryptoManager,
      githubService: harness.githubService,
      uploadIfNeeded: true,
    );
    final firstDevices = (firstRegistry!['devices'] as List<dynamic>)
        .cast<Map<String, dynamic>>();
    final linkedDevice = firstDevices.singleWhere(
      (device) => device['deviceId'] == 'phone-device',
    );

    expect(
      linkedDevice['registrationMethod'],
      SyncEngine.deviceRegistrationMethodLink,
    );
    expect(linkedDevice['linkedInviteId'], 'invite-1');
    expect(firstRegistry['pendingDeviceInvites'], isEmpty);
    expect(await harness.keyStorage.getPendingDeviceInviteId(), isNull);

    final uploadCountAfterLink = harness.githubService.uploadCount;
    final secondRegistry = await SyncEngine.refreshDeviceRegistry(
      keyStorage: harness.keyStorage,
      cryptoManager: harness.cryptoManager,
      githubService: harness.githubService,
      uploadIfNeeded: true,
    );
    final secondDevices = (secondRegistry!['devices'] as List<dynamic>)
        .cast<Map<String, dynamic>>();
    final refreshedDevice = secondDevices.singleWhere(
      (device) => device['deviceId'] == 'phone-device',
    );

    expect(
      refreshedDevice['registrationMethod'],
      SyncEngine.deviceRegistrationMethodLink,
    );
    expect(harness.githubService.uploadCount, uploadCountAfterLink);
  });

  test('new linked device with missing invite is rejected without writing',
      () async {
    final cryptoManager = CryptoManager();
    final rootKey = cryptoManager.generateRandomKey();
    final now = DateTime.now().toIso8601String();
    final harness = await _createHarnessWithRootKey(
      rootKey: rootKey,
      deviceId: 'phone-device',
      deviceName: 'Phone',
      cryptoManager: cryptoManager,
      registry: {
        'devices': [
          {
            'deviceId': 'trusted-device',
            'name': 'Trusted Laptop',
            'lastSeen': now,
            'addedAt': now,
            'registrationMethod': SyncEngine.deviceRegistrationMethodSetup,
          },
        ],
        'pendingDeviceInvites': const <Map<String, dynamic>>[],
      },
    );
    await harness.keyStorage.storeDeviceRegistrationMethod(
      SyncEngine.deviceRegistrationMethodLink,
    );
    await harness.keyStorage.storePendingDeviceInviteId('missing-invite');

    await expectLater(
      SyncEngine.refreshDeviceRegistry(
        keyStorage: harness.keyStorage,
        cryptoManager: harness.cryptoManager,
        githubService: harness.githubService,
        uploadIfNeeded: true,
      ),
      throwsStateError,
    );
    expect(harness.githubService.uploadCount, 0);
    expect(
      await harness.keyStorage.getPendingDeviceInviteId(),
      'missing-invite',
    );
  });

  test('recognized device is not downgraded by later refresh', () async {
    final cryptoManager = CryptoManager();
    final rootKey = cryptoManager.generateRandomKey();
    final now = DateTime.now().toIso8601String();
    final harness = await _createHarnessWithRootKey(
      rootKey: rootKey,
      deviceId: 'phone-device',
      deviceName: 'Phone',
      cryptoManager: cryptoManager,
      registry: {
        'devices': [
          {
            'deviceId': 'phone-device',
            'name': 'Phone',
            'lastSeen': now,
            'addedAt': now,
            'registrationMethod': SyncEngine.deviceRegistrationMethodRecognized,
            'recognizedByDeviceId': 'trusted-device',
          },
        ],
      },
    );
    await harness.keyStorage.storeDeviceRegistrationMethod(
      SyncEngine.deviceRegistrationMethodLink,
    );

    final registry = await SyncEngine.refreshDeviceRegistry(
      keyStorage: harness.keyStorage,
      cryptoManager: harness.cryptoManager,
      githubService: harness.githubService,
      uploadIfNeeded: true,
    );
    final devices =
        (registry!['devices'] as List<dynamic>).cast<Map<String, dynamic>>();

    expect(
      devices.single['registrationMethod'],
      SyncEngine.deviceRegistrationMethodRecognized,
    );
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
        .where(
          (path) =>
              path == Constants.indexFile ||
              path.startsWith('${Constants.dataFolder}/'),
        )
        .toList();

    expect(restoreResult.pulled, 1);
    expect(restoreResult.pushed, 0);
    expect(restoredEntries, hasLength(1));
    expect(restoredEntries.single.title, 'Example Gmail');
    expect(restoreUploadPaths, isEmpty);
  });

  test('revoking a trusted device removes it from trusted devices', () async {
    final now = DateTime.now().toIso8601String();
    final harness = await _createHarness({
      'devices': [
        {
          'deviceId': 'trusted-device',
          'name': 'Trusted Laptop',
          'lastSeen': now,
          'addedAt': now,
          'registrationMethod': SyncEngine.deviceRegistrationMethodSetup,
        },
        {
          'deviceId': 'phone-device',
          'name': 'Old Phone',
          'lastSeen': now,
          'addedAt': now,
          'registrationMethod': SyncEngine.deviceRegistrationMethodLink,
        },
      ],
      'pendingDeviceApprovals': [
        _approval(
          status: 'pending',
          expiresAt: DateTime.now().add(const Duration(seconds: 20)),
        )..['deviceId'] = 'phone-device',
      ],
      'pendingDeviceInvites': [
        {
          'inviteId': 'invite-from-phone',
          'createdAt': now,
          'expiresAt':
              DateTime.now().add(const Duration(minutes: 5)).toIso8601String(),
          'createdByDeviceId': 'phone-device',
          'createdByName': 'Old Phone',
        },
      ],
    });
    await harness.keyStorage.storeGitHubCredentials(
      token: 'current-token',
      repoOwner: 'owner',
      repoName: 'repo',
    );

    await SyncEngine.revokeTrustedDevice(
      keyStorage: harness.keyStorage,
      cryptoManager: harness.cryptoManager,
      githubService: harness.githubService,
      deviceId: 'phone-device',
    );

    final registry = await _decryptRegistry(harness);
    final devices =
        (registry['devices'] as List<dynamic>).cast<Map<String, dynamic>>();
    final revokedDevices = (registry['revokedDevices'] as List<dynamic>)
        .cast<Map<String, dynamic>>();
    final approvals = registry['pendingDeviceApprovals'] as List<dynamic>;
    final invites = registry['pendingDeviceInvites'] as List<dynamic>;

    expect(
      devices.any((device) => device['deviceId'] == 'phone-device'),
      isFalse,
    );
    expect(revokedDevices.single['deviceId'], 'phone-device');
    expect(approvals, isEmpty);
    expect(invites, isEmpty);
    expect(registry['activeGitHubTokenFingerprint'], isNotEmpty);
  });

  test('revoked device cannot refresh registry with the old token', () async {
    final cryptoManager = CryptoManager();
    final rootKey = cryptoManager.generateRandomKey();
    final oldFingerprint = await cryptoManager.hmacSha256(
      key: rootKey,
      data: 'github-token:old-token',
    );
    final harness = await _createHarnessWithRootKey(
      rootKey: rootKey,
      deviceId: 'phone-device',
      deviceName: 'Old Phone',
      registry: {
        'devices': const <Map<String, dynamic>>[],
        'revokedDevices': [
          {
            'deviceId': 'phone-device',
            'name': 'Old Phone',
            'revokedAt': DateTime.now().toIso8601String(),
          },
        ],
        'activeGitHubTokenFingerprint': oldFingerprint,
      },
    );
    await harness.keyStorage.storeGitHubCredentials(
      token: 'old-token',
      repoOwner: 'owner',
      repoName: 'repo',
    );

    await expectLater(
      SyncEngine.refreshDeviceRegistry(
        keyStorage: harness.keyStorage,
        cryptoManager: harness.cryptoManager,
        githubService: harness.githubService,
      ),
      throwsA(isA<DeviceRevokedException>()),
    );

    expect(harness.githubService.uploadCount, 0);
    expect(await harness.keyStorage.getGitHubToken(), isNull);
    expect(await harness.keyStorage.getRepoOwner(), isNull);
    expect(await harness.keyStorage.getRepoName(), isNull);
    expect(await harness.keyStorage.getAutoSyncInterval(), 0);
  });

  test('revoked device can refresh registry with a fresh GitHub token',
      () async {
    final cryptoManager = CryptoManager();
    final rootKey = cryptoManager.generateRandomKey();
    final oldFingerprint = await cryptoManager.hmacSha256(
      key: rootKey,
      data: 'github-token:old-token',
    );
    final harness = await _createHarnessWithRootKey(
      rootKey: rootKey,
      deviceId: 'phone-device',
      deviceName: 'Old Phone',
      registry: {
        'devices': const <Map<String, dynamic>>[],
        'revokedDevices': [
          {
            'deviceId': 'phone-device',
            'name': 'Old Phone',
            'revokedAt': DateTime.now().toIso8601String(),
          },
        ],
        'activeGitHubTokenFingerprint': oldFingerprint,
      },
    );
    await harness.keyStorage.storeGitHubCredentials(
      token: 'new-token',
      repoOwner: 'owner',
      repoName: 'repo',
    );

    final registry = await SyncEngine.refreshDeviceRegistry(
      keyStorage: harness.keyStorage,
      cryptoManager: harness.cryptoManager,
      githubService: harness.githubService,
    );
    final devices =
        (registry!['devices'] as List<dynamic>).cast<Map<String, dynamic>>();
    final revokedDevices = registry['revokedDevices'] as List<dynamic>;

    expect(revokedDevices, isEmpty);
    expect(devices.single['deviceId'], 'phone-device');
    expect(
      devices.single['registrationMethod'],
      SyncEngine.deviceRegistrationMethodRecoveryTokenRotated,
    );
    expect(registry['previousGitHubTokenFingerprint'], oldFingerprint);
    expect(registry['activeGitHubTokenFingerprint'], isNot(oldFingerprint));
  });

  test('heartbeat rebases approval and preserves unknown fields', () async {
    final h = await _createHarness({
      'devices': [
        {
          'deviceId': 'trusted-device',
          'name': 'Trusted Laptop',
          'registrationMethod': 'setup',
        }
      ],
      'pendingDeviceApprovals': [
        _approval(
          status: 'pending',
          expiresAt: DateTime.now().add(const Duration(seconds: 30)),
        ),
      ],
      'futureField': {'version': 7},
    });
    h.githubService.beforeWrite = () => _remoteEdit(h, (r) {
          (r['pendingDeviceApprovals'] as List).single.addAll({
            'status': 'approved',
            'respondedAt': DateTime.now().toUtc().toIso8601String(),
            'respondedByDeviceId': 'other-trusted-device',
            'respondedByName': 'Other Laptop',
          });
        });
    await _refresh(h);
    final r = await _decryptRegistry(h);
    expect((r['pendingDeviceApprovals'] as List).single['status'], 'approved');
    expect((r['devices'] as List).single['lastSeen'], isNotNull);
    expect(r['futureField'], {'version': 7});
    expect(h.githubService.conflicts, 1);
  });

  test('different concurrent approvals both survive', () async {
    final h = await _pendingHarness();
    await _remoteEdit(
      h,
      (r) => (r['pendingDeviceApprovals'] as List).add({
        ..._approval(
          status: 'pending',
          expiresAt: DateTime.now().add(const Duration(seconds: 30)),
        ),
        'approvalId': 'approval-2',
      }),
    );
    h.githubService.beforeWrite = () => _remoteEdit(h, (r) {
          (r['pendingDeviceApprovals'] as List)[1].addAll({
            'status': 'approved',
            'respondedAt': DateTime.now().toUtc().toIso8601String(),
            'respondedByDeviceId': 'other-trusted-device',
            'respondedByName': 'Other Laptop',
          });
        });
    await _respond(h);
    expect(
      (await _decryptRegistry(h))['pendingDeviceApprovals'],
      everyElement(containsPair('status', 'approved')),
    );
  });

  test('concurrent opposite answers cannot reverse first terminal answer',
      () async {
    final h = await _pendingHarness();
    h.githubService.beforeWrite = () => _remoteEdit(h, (r) {
          (r['pendingDeviceApprovals'] as List).single
            ..['status'] = 'denied'
            ..['respondedAt'] = DateTime.now().toIso8601String();
        });
    await expectLater(_respond(h), throwsStateError);
    expect(
      (await _decryptRegistry(h))['pendingDeviceApprovals'],
      everyElement(containsPair('status', 'denied')),
    );
  });

  test('revocation during refresh prevents trust resurrection', () async {
    final h = await _createHarness({
      'devices': [
        {'deviceId': 'trusted-device'},
      ],
    });
    h.githubService.beforeWrite = () => _remoteEdit(h, (r) {
          r['devices'] = [];
          r['revokedDevices'] = [
            {'deviceId': 'trusted-device'},
          ];
        });
    await expectLater(_refresh(h), throwsA(isA<DeviceRevokedException>()));
    expect((await _decryptRegistry(h))['devices'], isEmpty);
    expect(h.githubService.uploadCount, 0);
  });

  test('revoked approver cannot answer after conflict', () async {
    final h = await _pendingHarness();
    h.githubService.beforeWrite = () => _remoteEdit(h, (r) {
          r['revokedDevices'] = [
            {'deviceId': 'trusted-device'},
          ];
        });
    await expectLater(_respond(h), throwsA(isA<DeviceRevokedException>()));
    expect(
      (await _decryptRegistry(h))['pendingDeviceApprovals'],
      everyElement(containsPair('status', 'pending')),
    );
  });

  test('bounded retries reapply and recover without duplicate records',
      () async {
    final h = await _pendingHarness();
    h.githubService.forcedConflicts = DeviceRegistryStore.maxAttempts - 1;
    await _respond(h);
    expect(h.githubService.conflicts, DeviceRegistryStore.maxAttempts - 1);
    expect(h.githubService.uploadCount, 1);
    await _respond(h);
    expect(h.githubService.uploadCount, 1);
  });

  test('retry exhaustion marks cache stale and releases local queue', () async {
    final h = await _pendingHarness();
    await _refresh(h, upload: false);
    h.githubService.forcedConflicts = DeviceRegistryStore.maxAttempts;
    await expectLater(
      _respond(h),
      throwsA(
        isA<GitHubException>()
            .having((e) => e.kind, 'kind', 'conflict_exhausted'),
      ),
    );
    expect(
      jsonDecode((await h.keyStorage.getDeviceRegistrySnapshot())!)['stale'],
      true,
    );
    expect(h.githubService.uploadCount, 0);
    await _respond(h);
    expect(h.githubService.uploadCount, 1);
  });

  test('same-process operations are serialized without local conflicts',
      () async {
    final h = await _createHarness({
      'devices': [
        {'deviceId': 'phone', 'registrationMethod': 'sync'},
        {'deviceId': 'tablet', 'registrationMethod': 'sync'},
      ],
    });
    await Future.wait(
      ['phone', 'tablet'].map(
        (id) => SyncEngine.recognizeDeviceRegistration(
          keyStorage: h.keyStorage,
          cryptoManager: h.cryptoManager,
          githubService: h.githubService,
          deviceId: id,
        ),
      ),
    );
    expect(
      (await _decryptRegistry(h))['devices'],
      everyElement(containsPair('registrationMethod', 'recognized')),
    );
    expect(h.githubService.conflicts, 0);
  });

  test('ambiguous approval commit is confirmed by idempotent re-read',
      () async {
    final h = await _pendingHarness();
    h.githubService.failAfterCommit = true;
    await _respond(h);
    expect(h.githubService.uploadCount, 1);
    expect(
      (await _decryptRegistry(h))['pendingDeviceApprovals'],
      everyElement(containsPair('status', 'approved')),
    );
  });

  test('ambiguous invite and approval creation do not duplicate stable IDs',
      () async {
    final h = await _createHarness({'devices': []});
    h.githubService.failAfterCommit = true;
    final invite = await SyncEngine.createPendingDeviceInvite(
      keyStorage: h.keyStorage,
      cryptoManager: h.cryptoManager,
      githubService: h.githubService,
    );
    h.githubService.failAfterCommit = true;
    final approval = await SyncEngine.createPendingRecoveryApproval(
      keyStorage: h.keyStorage,
      cryptoManager: h.cryptoManager,
      githubService: h.githubService,
      rootKey: h.rootKey,
    );
    final r = await _decryptRegistry(h);
    expect((r['pendingDeviceInvites'] as List).single['inviteId'], invite);
    expect(
      (r['pendingDeviceApprovals'] as List).single['approvalId'],
      approval,
    );
    expect(h.githubService.uploadCount, 2);
  });

  test(
      'completion rebases unrelated update and repeating completion is a no-op',
      () async {
    final h = await _approvedHarness();
    h.githubService.beforeWrite = () => _remoteEdit(h, (r) {
          (r['devices'] as List)
              .add({'deviceId': 'concurrent-device', 'future': true});
        });
    await _complete(h);
    final r = await _decryptRegistry(h);
    expect((r['devices'] as List).length, 2);
    expect(
      (r['pendingDeviceApprovals'] as List).single['completedAt'],
      isNotNull,
    );
    final before = h.githubService.uploadCount;
    await _complete(h);
    expect(h.githubService.uploadCount, before);
  });

  test('completion is bound to requester and revoked device cannot replay it',
      () async {
    final h = await _approvedHarness();
    await h.keyStorage.storeDeviceId('different-device');
    await expectLater(_complete(h), throwsStateError);
    await h.keyStorage.storeDeviceId('trusted-device');
    await _remoteEdit(
      h,
      (r) => r['revokedDevices'] = [
        {'deviceId': 'trusted-device'},
      ],
    );
    await expectLater(_complete(h), throwsA(isA<DeviceRevokedException>()));
    expect(h.githubService.uploadCount, 0);
  });

  test('unknown and malformed approval state is never pending or approved',
      () async {
    for (final change in [
      {'status': 'future_state'},
      {'status': null},
      {'expiresAt': 'invalid'},
      {'expiresAt': null},
    ]) {
      final h = await _pendingHarness();
      await _remoteEdit(
        h,
        (r) => (r['pendingDeviceApprovals'] as List).single.addAll(change),
      );
      final status = await SyncEngine.getDeviceApprovalStatus(
        keyStorage: h.keyStorage,
        cryptoManager: h.cryptoManager,
        githubService: h.githubService,
        rootKey: h.rootKey,
        approvalId: 'approval-1',
      );
      expect(status.isExpired, true);
      await expectLater(_respond(h), throwsStateError);
      expect(
          h.githubService.uploadCount, change.containsKey('expiresAt') ? 1 : 0);
    }
  });

  test(
      'expiry uses remote time despite local clock skew and equality is expired',
      () async {
    final h = await _pendingHarness();
    final future = DateTime.now().toUtc().add(const Duration(days: 1));
    h.githubService.serverTime = future;
    await _remoteEdit(
      h,
      (r) => (r['pendingDeviceApprovals'] as List).single['expiresAt'] =
          future.toIso8601String(),
    );
    await expectLater(_respond(h), throwsStateError);
    expect(
      (await _decryptRegistry(h))['pendingDeviceApprovals'],
      everyElement(containsPair('status', 'expired')),
    );
  });

  test(
      'read-only refresh never consumes invites or manufactures own registration',
      () async {
    final h = await _createHarness({
      'devices': [],
      'pendingDeviceInvites': [
        {
          'inviteId': 'invite',
          'expiresAt':
              DateTime.now().add(const Duration(minutes: 1)).toIso8601String(),
        }
      ],
    });
    await h.keyStorage.storeDeviceRegistrationMethod('link');
    await h.keyStorage.storePendingDeviceInviteId('invite');
    final r = await _refresh(h, upload: false);
    expect(r!['devices'], isEmpty);
    expect((r['pendingDeviceInvites'] as List).length, 1);
    expect(await h.keyStorage.getPendingDeviceInviteId(), 'invite');
    expect(h.githubService.uploadCount, 0);
  });

  test('failed invite consumption keeps local invite for retry', () async {
    final h = await _createHarness({
      'devices': [],
      'pendingDeviceInvites': [
        {
          'inviteId': 'invite',
          'expiresAt':
              DateTime.now().add(const Duration(minutes: 1)).toIso8601String(),
        }
      ],
    });
    await h.keyStorage.storeDeviceRegistrationMethod('link');
    await h.keyStorage.storePendingDeviceInviteId('invite');
    h.githubService.writeError =
        GitHubException('Rate limited', statusCode: 429);
    await expectLater(_refresh(h), throwsA(isA<GitHubException>()));
    expect(await h.keyStorage.getPendingDeviceInviteId(), 'invite');
    h.githubService.writeError = null;
    await _refresh(h);
    expect(await h.keyStorage.getPendingDeviceInviteId(), null);
    expect((await _decryptRegistry(h))['pendingDeviceInvites'], isEmpty);
    await h.keyStorage.storeDeviceId('another-device');
    await h.keyStorage.storePendingDeviceInviteId('invite');
    await expectLater(_refresh(h), throwsStateError);
  });

  test('approval survives concurrent invite consumption', () async {
    final h = await _pendingHarness();
    await h.keyStorage.storeDeviceRegistrationMethod('link');
    await h.keyStorage.storePendingDeviceInviteId('invite');
    await _remoteEdit(
      h,
      (r) => r['pendingDeviceInvites'] = [
        {
          'inviteId': 'invite',
          'expiresAt':
              DateTime.now().add(const Duration(minutes: 1)).toIso8601String(),
        }
      ],
    );
    h.githubService.beforeWrite = () => _remoteEdit(
          h,
          (r) => (r['pendingDeviceApprovals'] as List).single['status'] =
              'approved',
        );
    await _refresh(h);
    final r = await _decryptRegistry(h);
    expect((r['pendingDeviceApprovals'] as List).single['status'], 'approved');
    expect(r['pendingDeviceInvites'], isEmpty);
    expect((r['devices'] as List).single['registrationMethod'], 'link');
  });

  for (final status in [401, 403, 429, 500, 502, 503]) {
    test(
        'HTTP $status read failure cannot upload fallback and stales scoped cache',
        () async {
      final h = await _pendingHarness();
      await _refresh(h, upload: false);
      final before = await h.keyStorage.getDeviceRegistry();
      h.githubService.readError =
          GitHubException('Unavailable', statusCode: status);
      await expectLater(_refresh(h), throwsA(isA<GitHubException>()));
      expect(h.githubService.uploadCount, 0);
      expect(await h.keyStorage.getDeviceRegistry(), before);
      final cache =
          jsonDecode((await h.keyStorage.getDeviceRegistrySnapshot())!);
      expect(cache['stale'], true);
      expect(cache['scope'], h.githubService.registryScope);
      expect(cache['sha'], isNotNull);
    });
  }

  test(
      'missing registry only initializes in explicit setup with no known registry',
      () async {
    final h = await _createHarness({'devices': []});
    h.githubService.files.clear();
    await expectLater(_refresh(h), throwsA(isA<GitHubException>()));
    await h.keyStorage.storeDeviceRegistrationMethod('setup');
    await _refresh(h);
    expect(h.githubService.uploadCount, 1);
    h.githubService.files.clear();
    await expectLater(_refresh(h), throwsA(isA<GitHubException>()));
    expect(h.githubService.uploadCount, 1);
  });

  for (final invalid in [
    Uint8List(0),
    Uint8List.fromList([1, 2, 3]),
  ]) {
    test('invalid ciphertext cannot cause fallback upload ${invalid.length}',
        () async {
      final h = await _createHarness({'devices': []});
      h.githubService.files[Constants.trustedDevicesFile] = invalid;
      await expectLater(_refresh(h), throwsA(isA<GitHubException>()));
      expect(h.githubService.uploadCount, 0);
    });
  }

  for (final invalid in [
    {'devices': 'invalid'},
    {
      'devices': [
        {'deviceId': 'same'},
        {'deviceId': 'same'},
      ],
    },
    {
      'pendingDeviceApprovals': [42],
    },
    {
      'devices': [
        {'name': 'no id'},
      ],
    },
    {
      'devices': [
        {'deviceId': 'phone', 'registrationMethod': 42}
      ]
    },
    {
      'pendingDeviceApprovals': [
        {'approvalId': 'r1', 'status': true}
      ]
    },
    {'activeGitHubTokenFingerprint': 42},
  ]) {
    test('malformed registry types and duplicate IDs fail closed $invalid',
        () async {
      final h = await _createHarness(invalid);
      await expectLater(_refresh(h), throwsA(isA<GitHubException>()));
      expect(h.githubService.uploadCount, 0);
    });
  }

  test('wrong root key does not update cache or upload', () async {
    final h = await _pendingHarness();
    await h.keyStorage.storeRootKey(h.cryptoManager.generateRandomKey());
    await expectLater(_refresh(h), throwsA(isA<GitHubException>()));
    expect(h.githubService.uploadCount, 0);
    expect(await h.keyStorage.getDeviceRegistry(), null);
  });

  test('post-commit cache failure preserves remote success', () async {
    final storage = _FailingCacheStorage();
    final crypto = CryptoManager();
    final h = await _createHarnessWithRootKey(
      rootKey: crypto.generateRandomKey(),
      deviceId: 'trusted-device',
      deviceName: 'Trusted Laptop',
      storage: storage,
      registry: {
        'devices': [],
        'pendingDeviceApprovals': [
          _approval(
            status: 'pending',
            expiresAt: DateTime.now().add(const Duration(seconds: 30)),
          ),
        ],
      },
    );
    await _respond(h);
    expect(h.githubService.uploadCount, 1);
    expect(
      (await _decryptRegistry(h))['pendingDeviceApprovals'],
      everyElement(containsPair('status', 'approved')),
    );
  });

  test('completed approval without matching registration cannot report success',
      () async {
    final h = await _approvedHarness();
    await _remoteEdit(
      h,
      (r) => (r['pendingDeviceApprovals'] as List).single['completedAt'] =
          DateTime.now().toIso8601String(),
    );
    await expectLater(_complete(h), throwsStateError);
    expect(h.githubService.uploadCount, 0);
  });

  test(
      'approved completion preserves existing trusted method and creation time',
      () async {
    final h = await _approvedHarness();
    await _remoteEdit(
      h,
      (r) => r['devices'] = [
        {
          'deviceId': 'trusted-device',
          'registrationMethod': 'recognized',
          'addedAt': '2020-01-01T00:00:00Z',
          'custom': true,
        }
      ],
    );
    await _complete(h);
    final device = ((await _decryptRegistry(h))['devices'] as List).single;
    expect(device['registrationMethod'], 'recognized');
    expect(device['addedAt'], '2020-01-01T00:00:00Z');
    expect(device['custom'], true);
    expect(device['recoveryApprovalId'], 'approval-1');
  });

  test('browser snapshots without Date header use explicit local-clock policy',
      () async {
    final h = await _pendingHarness();
    h.githubService.omitServerTime = true;
    await _respond(h);
    final cached =
        jsonDecode((await h.keyStorage.getDeviceRegistrySnapshot())!);
    expect(cached['clockSource'], 'local');
    expect(cached['stale'], false);
  });

  test('expired linked invite cannot upgrade existing unverified registration',
      () async {
    final h = await _createHarness({
      'devices': [
        {'deviceId': 'trusted-device', 'registrationMethod': 'sync'},
      ],
      'pendingDeviceInvites': [
        {
          'inviteId': 'expired-invite',
          'createdByDeviceId': 'other-trusted-device',
          'expiresAt': DateTime.now()
              .subtract(const Duration(seconds: 1))
              .toUtc()
              .toIso8601String(),
        },
      ],
    });
    await h.keyStorage.storeDeviceRegistrationMethod('link');
    await h.keyStorage.storePendingDeviceInviteId('expired-invite');
    await expectLater(_refresh(h), throwsStateError);
    expect(h.githubService.uploadCount, 0);
  });

  test('case-sensitive IDs target records independently of display names',
      () async {
    final h = await _createHarness({
      'devices': [
        {'deviceId': 'phone', 'name': 'Same', 'registrationMethod': 'sync'},
        {'deviceId': 'Phone', 'name': 'Same', 'registrationMethod': 'sync'},
      ],
    });
    await SyncEngine.recognizeDeviceRegistration(
      keyStorage: h.keyStorage,
      cryptoManager: h.cryptoManager,
      githubService: h.githubService,
      deviceId: 'phone',
    );
    final devices = (await _decryptRegistry(h))['devices'] as List;
    expect(devices[0]['registrationMethod'], 'recognized');
    expect(devices[1]['registrationMethod'], 'sync');
  });

  test('diagnostics contain hashed identifiers and no decrypted content',
      () async {
    final h = await _pendingHarness();
    final captured = <String>[];
    final original = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      if (message != null) captured.add(message);
    };
    try {
      h.githubService.forcedConflicts = 2;
      await _respond(h);
    } finally {
      debugPrint = original;
    }
    final event = jsonDecode(captured.last) as Map;
    expect(event['conflicts'], 2);
    expect(event['deviceIdHash'], isNotNull);
    expect(event['requestIdHash'], isNotNull);
    expect(event['clockSource'], 'github');
    for (final secret in [
      'trusted-device',
      'approval-1',
      'Trusted Laptop',
      'test-token',
      base64Encode(h.rootKey),
      'pendingDeviceApprovals',
    ]) {
      expect(captured.join(), isNot(contains(secret)));
    }
  });

  test(
      'repeated competing writes are rebased with every unrelated update intact',
      () async {
    final h = await _pendingHarness();
    var updates = 0;
    late Future<void> Function() compete;
    compete = () async {
      updates++;
      await _remoteEdit(h, (r) => r['concurrent-$updates'] = true);
      if (updates < 3) h.githubService.beforeWrite = compete;
    };
    h.githubService.beforeWrite = compete;
    await _respond(h);
    final registry = await _decryptRegistry(h);
    for (var i = 1; i <= 3; i++) {
      expect(registry['concurrent-$i'], true);
    }
    expect(h.githubService.conflicts, 3);
  });

  test('token-rotated recovery clears existing device revocation', () async {
    final cryptoManager = CryptoManager();
    final rootKey = cryptoManager.generateRandomKey();
    final oldFingerprint = await cryptoManager.hmacSha256(
      key: rootKey,
      data: 'github-token:old-token',
    );
    final harness = await _createHarnessWithRootKey(
      rootKey: rootKey,
      deviceId: 'phone-device',
      deviceName: 'Old Phone',
      registry: {
        'devices': const <Map<String, dynamic>>[],
        'revokedDevices': [
          {
            'deviceId': 'phone-device',
            'name': 'Old Phone',
            'revokedAt': DateTime.now().toIso8601String(),
          },
        ],
        'activeGitHubTokenFingerprint': oldFingerprint,
      },
    );

    await SyncEngine.completeTokenRotatedRecovery(
      keyStorage: harness.keyStorage,
      cryptoManager: harness.cryptoManager,
      githubService: harness.githubService,
      rootKey: rootKey,
      oldToken: 'old-token',
      newToken: 'new-token',
      approvalId: 'approval-1',
    );

    final registry = await _decryptRegistry(harness);
    final devices =
        (registry['devices'] as List<dynamic>).cast<Map<String, dynamic>>();
    final revokedDevices = registry['revokedDevices'] as List<dynamic>;

    expect(revokedDevices, isEmpty);
    expect(devices.single['deviceId'], 'phone-device');
    expect(
      devices.single['registrationMethod'],
      SyncEngine.deviceRegistrationMethodRecoveryTokenRotated,
    );
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

Future<void> _remoteEdit(
  _Harness h,
  void Function(Map<String, dynamic>) edit,
) async {
  final registry = await _decryptRegistry(h);
  edit(registry);
  h.githubService.files[Constants.trustedDevicesFile] =
      await _encryptRegistry(registry, h.cryptoManager, h.rootKey);
}

Future<_Harness> _pendingHarness() => _createHarness({
      'devices': [],
      'pendingDeviceApprovals': [
        _approval(
          status: 'pending',
          expiresAt: DateTime.now().add(const Duration(seconds: 30)),
        ),
      ],
    });

Future<_Harness> _approvedHarness() => _createHarness({
      'devices': [],
      'pendingDeviceApprovals': [
        {
          ..._approval(
            status: 'approved',
            expiresAt: DateTime.now().add(const Duration(seconds: 30)),
            respondedAt: DateTime.now(),
          ),
          'deviceId': 'trusted-device',
        }
      ],
    });

Future<Map<String, dynamic>?> _refresh(_Harness h, {bool upload = true}) =>
    SyncEngine.refreshDeviceRegistry(
      keyStorage: h.keyStorage,
      cryptoManager: h.cryptoManager,
      githubService: h.githubService,
      uploadIfNeeded: upload,
    );

Future<void> _respond(_Harness h) => SyncEngine.respondToDeviceApproval(
      keyStorage: h.keyStorage,
      cryptoManager: h.cryptoManager,
      githubService: h.githubService,
      approvalId: 'approval-1',
      approved: true,
    );

Future<void> _complete(_Harness h) => SyncEngine.completeApprovedRecovery(
      keyStorage: h.keyStorage,
      cryptoManager: h.cryptoManager,
      githubService: h.githubService,
      rootKey: h.rootKey,
      approvalId: 'approval-1',
    );

class _FailingCacheStorage extends KeyStorage {
  @override
  Future<void> storeDeviceRegistrySnapshot(String envelope) async {
    throw StateError('Storage unavailable');
  }
}

Future<_Harness> _createHarness(Map<String, dynamic> registry) async {
  final cryptoManager = CryptoManager();
  final rootKey = cryptoManager.generateRandomKey();
  return _createHarnessWithRootKey(
    rootKey: rootKey,
    deviceId: 'trusted-device',
    deviceName: 'Trusted Laptop',
    cryptoManager: cryptoManager,
    registry: registry,
  );
}

Future<_Harness> _createHarnessWithRootKey({
  required Uint8List rootKey,
  required String deviceId,
  required String deviceName,
  required Map<String, dynamic> registry,
  CryptoManager? cryptoManager,
  KeyStorage? storage,
}) async {
  final manager = cryptoManager ?? CryptoManager();
  final keyStorage = storage ?? KeyStorage();
  await keyStorage.initialize();
  await keyStorage.storeRootKey(rootKey);
  await keyStorage.storeDeviceId(deviceId);
  await keyStorage.storeLocalDeviceName(deviceName);

  final githubService = _MemoryGitHubService({
    Constants.trustedDevicesFile: await _encryptRegistry(
      registry,
      manager,
      rootKey,
    ),
  });

  return _Harness(
    keyStorage: keyStorage,
    cryptoManager: manager,
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
  Future<void> Function()? beforeWrite;
  int conflicts = 0;
  int forcedConflicts = 0;
  Object? readError;
  Object? writeError;
  bool failAfterCommit = false;
  DateTime? serverTime;
  bool omitServerTime = false;

  String? _sha(String path) =>
      files[path] == null ? null : sha256.convert(files[path]!).toString();

  @override
  Future<RemoteFileSnapshot> readFileSnapshot(String path) async {
    if (readError != null) throw readError!;
    final bytes = files[path];
    return bytes == null
        ? const RemoteFileSnapshot.missing()
        : RemoteFileSnapshot(
            bytes: Uint8List.fromList(bytes),
            sha: _sha(path),
            serverTime:
                omitServerTime ? null : serverTime ?? DateTime.now().toUtc(),
          );
  }

  @override
  Future<String> writeFileSnapshot({
    required String path,
    required Uint8List content,
    required String? expectedSha,
    required String commitMessage,
  }) async {
    final hook = beforeWrite;
    beforeWrite = null;
    await hook?.call();
    if (forcedConflicts > 0 || expectedSha != _sha(path)) {
      if (forcedConflicts > 0) forcedConflicts--;
      conflicts++;
      throw GitHubException('Conflict', statusCode: 409);
    }
    if (writeError != null) throw writeError!;
    uploadCount++;
    uploadedPaths.add(path);
    files[path] = Uint8List.fromList(content);
    if (failAfterCommit) {
      failAfterCommit = false;
      throw GitHubException('Response lost', kind: 'network');
    }
    return _sha(path)!;
  }

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
    final hook = beforeWrite;
    beforeWrite = null;
    await hook?.call();
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
