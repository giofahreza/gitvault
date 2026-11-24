import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitvault/core/crypto/blind_handshake.dart';
import 'package:gitvault/core/services/github_service.dart';
import 'package:gitvault/data/repositories/notes_repository.dart';
import 'package:gitvault/data/repositories/sync_engine.dart';
import 'package:gitvault/data/repositories/vault_repository.dart';
import 'package:hive/hive.dart';

import 'support/memory_registry_storage.dart';
import 'support/registry_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late RegistryFixture f;
  late MemoryRegistryStorage source, target;

  Future<void> clearLocalVault() async {
    await Hive.close();
    for (final box in ['vault_entries', 'notes', 'sync_metadata']) {
      await Hive.deleteBoxFromDisk(box);
    }
  }

  ({SyncEngine sync, VaultRepository vault, NotesRepository notes}) engine(
      MemoryRegistryStorage storage) {
    final vault = VaultRepository(cryptoManager: f.crypto, keyStorage: storage);
    final notes = NotesRepository(cryptoManager: f.crypto, keyStorage: storage);
    return (
      sync: SyncEngine(
          vaultRepository: vault,
          notesRepository: notes,
          githubService: f.remote,
          cryptoManager: f.crypto,
          keyStorage: storage),
      vault: vault,
      notes: notes
    );
  }

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.giofahreza.gitvault/ime'),
            (_) async => null);
    directory =
        await Directory.systemTemp.createTemp('gitvault-full-recovery-');
    Hive.init(directory.path);
    f = RegistryFixture();
    await f.seed({'devices': []});
    source = await f.device('source');
    target = await f.device('target', method: 'recovery');
    final setup = engine(source);
    await setup.sync.initialize();
    await setup.vault.createEntry(
        title: 'Restored login',
        username: 'alice',
        password: 'password-canary');
    await setup.notes
        .createNote(title: 'Restored note', content: 'note-canary');
    final initialSync = await setup.sync.sync();
    expect(initialSync.pushed, 2);
    await clearLocalVault();
  });
  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  for (final method in ['approval', 'token', 'link']) {
    test(
        'TC-E2E-001/005/006 local $method registration restores real encrypted vault',
        () async {
      final id = await f.request(target);
      if (method == 'approval') {
        await f.respond(source, id);
        expect((await f.status(target, id)).isApproved, true);
        await f.complete(target, id);
        target.method = 'recovery_approved';
      } else if (method == 'token') {
        await SyncEngine.completeTokenRotatedRecovery(
            keyStorage: target,
            cryptoManager: f.crypto,
            githubService: f.remote,
            rootKey: f.root,
            oldToken: 'token-canary',
            newToken: 'fresh-token',
            approvalId: id);
        target.method = 'recovery_token_rotated';
        target.token = 'fresh-token';
      } else {
        final invite = await f.invite(source);
        final handshake = BlindHandshake(cryptoManager: f.crypto);
        final payload = await handshake.generateLinkingPayload(
            rootKey: f.root,
            githubToken: 'token-canary',
            repoOwner: 'fixture-owner',
            repoName: 'fixture-repo',
            deviceInviteId: invite);
        final scanned = await handshake.decryptLinkingPayload(
            qrData: payload.qrData, pin: payload.displayPIN);
        target.root = scanned.rootKey;
        target.invite = scanned.deviceInviteId;
        target.method = 'link';
        await f.refresh(target);
      }
      final uploads = f.remote.vaultUploads.length;
      final recovered = engine(target);
      await recovered.sync.initialize();
      final result = await recovered.sync.restoreFromGitHub();
      expect(result.pulled, 2);
      expect(result.pushed, 0);
      expect(f.remote.vaultUploads.length, uploads);
      final entries = await recovered.vault.getAllEntries();
      expect(entries.single.password, 'password-canary');
      expect((await recovered.notes.getAllStoredNotes()).single.content,
          'note-canary');
      final registry = await f.decode();
      final registered = (registry['devices'] as List)
          .cast<Map>()
          .singleWhere((d) => d['deviceId'] == 'target');
      expect(registered['registrationMethod'], target.method);
      // Reopen real local storage; restoration must survive repository instances.
      await Hive.close();
      final reopened = engine(target);
      await reopened.sync.initialize();
      expect((await reopened.vault.getAllEntries()).single.title,
          'Restored login');
    });
  }

  test('TC-MODAL-010 real restore failure leaves durable approval retryable',
      () async {
    final id = await f.request(target);
    await f.respond(source, id);
    await f.complete(target, id);
    target.method = 'recovery_approved';
    final recovered = engine(target);
    await recovered.sync.initialize();
    f.remote.downloadError = GitHubException('Offline', kind: 'network');
    await expectLater(
        recovered.sync.restoreFromGitHub(), throwsA(isA<SyncException>()));
    final registry = await f.decode();
    expect(
        registry['devices'], contains(containsPair('recoveryApprovalId', id)));
    expect((registry['pendingDeviceApprovals'] as List).single['completedAt'],
        isNotNull);
    f.remote.downloadError = null;
    expect((await recovered.sync.restoreFromGitHub()).pulled, 2);
    expect(
        (await recovered.vault.getAllEntries()).single.title, 'Restored login');
  });

  test('TC-SEC-004 corrupt registry blocks normal sync with a confirmed cache',
      () async {
    await f.refresh(source, upload: false);
    final confirmed = jsonDecode(source.snapshot!) as Map;
    final local = engine(source);
    await local.sync.initialize();
    await local.notes
        .createNote(title: 'Offline edit', content: 'Must stay local');
    f.remote.bytes = Uint8List.fromList(f.remote.bytes!);
    f.remote.bytes![f.remote.bytes!.length - 1] ^= 1;
    final corrupted = Uint8List.fromList(f.remote.bytes!);
    final registryWrites = f.remote.writes;
    final vaultUploads = f.remote.vaultUploads.length;
    await expectLater(local.sync.sync(), throwsA(isA<GitHubException>()));
    final cached = jsonDecode(source.snapshot!) as Map;
    expect(cached['registry'], confirmed['registry']);
    expect(cached['sha'], confirmed['sha']);
    expect(cached['stale'], true);
    expect(f.remote.bytes, corrupted);
    expect(f.remote.writes, registryWrites);
    expect(f.remote.vaultUploads.length, vaultUploads);
    expect((await local.notes.getAllStoredNotes()).single.content,
        'Must stay local');
  });

  test('TC-E2E-002 third-device normal sync rebases during recovery', () async {
    final third = await f.device('third');
    final local = engine(third);
    await local.sync.initialize();
    await local.notes
        .createNote(title: 'Third-device edit', content: 'Concurrent');
    final id = await f.request(target);
    // Complete a real approval between the normal sync GET and its CAS PUT.
    f.remote.beforeWrite = () => f.edit((registry) {
          final approval = (registry['pendingDeviceApprovals'] as List)
              .cast<Map>()
              .singleWhere((a) => a['approvalId'] == id);
          approval.addAll(<String, dynamic>{
            'status': 'approved',
            'respondedAt': DateTime.now().toUtc().toIso8601String(),
            'respondedByDeviceId': 'source',
            'respondedByName': 'Name source',
          });
        });
    final result = await local.sync.sync();
    expect(f.remote.conflicts, 1);
    expect(result.pushed, 1);
    expect((await f.status(target, id)).isApproved, true);
    await f.complete(target, id);
    target.method = 'recovery_approved';
    await clearLocalVault();
    final recovered = engine(target);
    await recovered.sync.initialize();
    expect((await recovered.sync.restoreFromGitHub()).pulled, 3);
    expect((await recovered.notes.getAllStoredNotes()).map((n) => n.title),
        unorderedEquals(['Restored note', 'Third-device edit']));
    expect(((await f.decode())['devices'] as List).map((d) => d['deviceId']),
        containsAll(['source', 'third', 'target']));
  });

  test('TC-E2E-003/004 offline source reconnects before versus after expiry',
      () async {
    final id = await f.request(target);
    f.remote.readError = GitHubException('Offline', kind: 'network');
    await expectLater(f.respond(source, id), throwsA(isA<GitHubException>()));
    f.remote.readError = null;
    await f.respond(source, id);
    await f.complete(target, id);
    final next = await f.request(target);
    f.remote.serverTime =
        DateTime.now().toUtc().add(const Duration(minutes: 1));
    await expectLater(f.respond(source, next), throwsStateError);
    expect((await f.status(target, next)).isExpired, true);
    final fresh = await f.request(target);
    expect(fresh, isNot(next));
    expect((await f.status(target, fresh)).isPending, true);
  });

  test('TC-E2E-007 intermittent HTTP failures preserve request through restore',
      () async {
    final id = await f.request(target);
    for (final status in [429, 500, 429]) {
      f.remote.readError = GitHubException('Unavailable',
          statusCode: status, kind: status == 429 ? 'rate_limit' : 'http');
      await expectLater(f.respond(source, id), throwsA(isA<GitHubException>()));
      f.remote.readError = null;
      expect((await f.status(target, id)).isPending, true);
    }
    await f.respond(source, id);
    await f.complete(target, id);
    target.method = 'recovery_approved';
    final recovered = engine(target);
    await recovered.sync.initialize();
    expect((await recovered.sync.restoreFromGitHub()).pulled, 2);
    expect((await recovered.vault.getAllEntries()).single.password,
        'password-canary');
  });
}
