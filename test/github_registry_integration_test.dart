import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:gitvault/core/crypto/crypto_manager.dart';
import 'package:gitvault/core/services/github_service.dart';
import 'package:gitvault/data/repositories/device_registry_store.dart';
import 'package:gitvault/utils/constants.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'support/memory_registry_storage.dart';

/// Opt-in only; creates a unique test file, never the live registry.
class _IsolatedRegistryService extends GitHubService {
  final String testPath;
  Future<void> Function()? beforeWrite;
  int conflicts = 0;
  _IsolatedRegistryService({
    required super.accessToken,
    required super.repoOwner,
    required super.repoName,
    required this.testPath,
  });
  @override
  Future<RemoteFileSnapshot> readFileSnapshot(String path) =>
      super.readFileSnapshot(testPath);
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
    try {
      return await super.writeFileSnapshot(
        path: testPath,
        content: content,
        expectedSha: expectedSha,
        commitMessage: commitMessage,
      );
    } on GitHubException catch (error) {
      if (error.isConflict) conflicts++;
      rethrow;
    }
  }
}

void main() {
  final env = Platform.environment;
  final enabled = env['GITVAULT_RUN_GITHUB_INTEGRATION'] == '1' &&
      [
        'GITVAULT_TEST_GITHUB_TOKEN',
        'GITVAULT_TEST_REPO_OWNER',
        'GITVAULT_TEST_REPO_NAME',
      ].every((key) => env[key]?.isNotEmpty == true);
  test(
    'real GitHub conflict rebases encrypted approval over heartbeat',
    () async {
      final path = 'integration-tests/${const Uuid().v4()}/trusted_devices.bin';
      final remote = _IsolatedRegistryService(
        accessToken: env['GITVAULT_TEST_GITHUB_TOKEN']!,
        repoOwner: env['GITVAULT_TEST_REPO_OWNER']!,
        repoName: env['GITVAULT_TEST_REPO_NAME']!,
        testPath: path,
      );
      final competing = GitHubService(
        accessToken: env['GITVAULT_TEST_GITHUB_TOKEN']!,
        repoOwner: env['GITVAULT_TEST_REPO_OWNER']!,
        repoName: env['GITVAULT_TEST_REPO_NAME']!,
      );
      final crypto = CryptoManager();
      final key = crypto.generateRandomKey();
      Future<Uint8List> encrypt(Map<String, dynamic> registry) async =>
          (await crypto.encryptXChaCha20(
            data: crypto.addRandomPadding(
              Uint8List.fromList(utf8.encode(jsonEncode(registry))),
            ),
            key: key,
          ))
              .toBytes();
      final initial = <String, dynamic>{
        'devices': [
          {'deviceId': 'heartbeat-device'},
        ],
        'pendingDeviceApprovals': [
          {'approvalId': 'r1', 'status': 'pending'},
        ],
      };
      final store = DeviceRegistryStore(
        keyStorage: MemoryRegistryStorage(),
        cryptoManager: crypto,
        githubService: remote,
        rootKey: key,
      );
      try {
        await remote.writeFileSnapshot(
          path: Constants.trustedDevicesFile,
          content: await encrypt(initial),
          expectedSha: null,
          commitMessage: 'Registry integration fixture',
        );
        remote.beforeWrite = () async {
          final snapshot = await competing.readFileSnapshot(path);
          final updated = <String, dynamic>{
            ...initial,
            'devices': [
              {
                'deviceId': 'heartbeat-device',
                'lastSeen': 'concurrent heartbeat',
              },
            ],
          };
          await competing.writeFileSnapshot(
            path: path,
            content: await encrypt(updated),
            expectedSha: snapshot.sha,
            commitMessage: 'Registry integration concurrent heartbeat',
          );
        };
        await store.mutate(
          operation: 'Registry integration approve',
          apply: (registry, now) async {
            (registry['pendingDeviceApprovals'] as List).single['status'] =
                'approved';
          },
        );
        final finalRegistry = await store.read();
        expect(
          (finalRegistry['devices'] as List).single['lastSeen'],
          'concurrent heartbeat',
        );
        expect(
          (finalRegistry['pendingDeviceApprovals'] as List).single['status'],
          'approved',
        );
        expect(remote.conflicts, greaterThanOrEqualTo(1));
      } finally {
        try {
          await competing.deleteFile(
            path: path,
            commitMessage: 'Remove registry integration fixture',
          );
        } finally {
          remote.dispose();
          competing.dispose();
        }
      }
    },
    skip: enabled
        ? false
        : 'Requires explicit opt-in and a disposable GitHub test repository with an existing data branch.',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
