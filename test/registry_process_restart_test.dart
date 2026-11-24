import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:gitvault/data/repositories/notes_repository.dart';
import 'package:gitvault/data/repositories/vault_repository.dart';
import 'package:gitvault/data/repositories/sync_engine.dart';
import 'package:gitvault/data/repositories/ssh_repository.dart';
import 'package:gitvault/data/models/ssh_credential.dart';
import 'package:gitvault/data/models/note.dart';
import 'package:hive/hive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/registry_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isMacOS && !Platform.isLinux) {
    test('POSIX registry process termination and restart', () {},
        skip:
            'SIGKILL/Flutter bundle harness requires a macOS or Linux runner.');
    return;
  }
  late Directory build;
  late Directory sandbox;
  late RegistryFixture f;
  late File remote;
  late Map<String, String> childEnvironment;

  setUpAll(() async {
    build = await Directory.systemTemp.createTemp('registry-process-assets-');
    final flutter = Platform.environment['GITVAULT_TEST_FLUTTER'] ??
        p.normalize(p.join(p.dirname(Platform.resolvedExecutable), '..', '..',
            '..', '..', 'flutter'));
    final result = await Process.run(
        flutter,
        [
          'build',
          'bundle',
          '--debug',
          '--no-pub',
          '--target-platform=${Platform.isMacOS ? 'darwin' : 'linux-x64'}',
          '--target=test/support/registry_process_probe.dart',
          '--asset-dir=${build.path}',
          '--depfile=${build.path}/probe.d'
        ],
        workingDirectory: Directory.current.path);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });
  tearDownAll(() async => build.delete(recursive: true));
  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('registry-process-state-');
    f = RegistryFixture();
    remote = File('${sandbox.path}/remote.enc');
    await f.seed({
      'devices': [
        {'deviceId': 'source', 'registrationMethod': 'setup'}
      ],
      'pendingDeviceApprovals': [
        {
          'approvalId': 'request',
          'deviceId': 'target',
          'status': 'approved',
          'requestedAt': '2029-12-31T23:59:40Z',
          'expiresAt': '2030-01-01T00:00:10Z',
          'respondedAt': '2029-12-31T23:59:50Z',
          'respondedByDeviceId': 'source',
        }
      ],
    });
    await remote.writeAsBytes(f.remote.bytes!, flush: true);
    final local = await Directory('${sandbox.path}/local').create();
    childEnvironment = {
      ...Platform.environment,
      'GITVAULT_PROBE_LOCAL': local.path,
      'GITVAULT_PROBE_REMOTE': remote.path,
      'GITVAULT_PROBE_ROOT': base64Encode(f.root),
    };
  });
  tearDown(() async => sandbox.delete(recursive: true));

  Future<Process> launch(
      {String boundary = '', String action = 'complete', String? cache}) async {
    return Process.start(Platform.resolvedExecutable, [
      '--non-interactive',
      '--disable-vm-service',
      '--flutter-assets-dir=${build.path}',
      '${build.path}/kernel_blob.bin',
    ], environment: {
      ...childEnvironment,
      'GITVAULT_PROBE_BOUNDARY': boundary,
      'GITVAULT_PROBE_ACTION': action,
      if (cache != null) 'GITVAULT_PROBE_CACHE': cache,
    });
  }

  Future<String> finish(Process process) async {
    final output = process.stdout.transform(utf8.decoder).join();
    final errors = process.stderr.transform(utf8.decoder).join();
    expect(await process.exitCode.timeout(const Duration(seconds: 20)), 0,
        reason: await errors);
    return output;
  }

  for (final boundary in [
    'after-registration',
    'before-credentials',
    'after-credentials',
    'before-key',
    'after-key',
    'before-restore',
    'during-restore',
    'after-vault-restore',
    'after-ssh-restore',
    'after-restore'
  ]) {
    test('TC-E2E-008 real SIGKILL and encrypted restore restart $boundary',
        () async {
      final sourceDirectory =
          await Directory('${sandbox.path}/source').create();
      Hive.init(sourceDirectory.path);
      final source = await f.device('source');
      final notes =
          NotesRepository(cryptoManager: f.crypto, keyStorage: source);
      final vault =
          VaultRepository(cryptoManager: f.crypto, keyStorage: source);
      final ssh = SshRepository(cryptoManager: f.crypto, keyStorage: source);
      final sync = SyncEngine(
          vaultRepository: vault,
          notesRepository: notes,
          sshRepository: ssh,
          githubService: f.remote,
          cryptoManager: f.crypto,
          keyStorage: source);
      await sync.initialize();
      for (var i = 0; i < 2; i++) {
        await notes.createNote(title: 'Durable $i', content: 'durable-note-$i');
      }
      await notes.createNote(
          title: 'Checklist',
          content: '',
          formatVersion: 1,
          isChecklist: true,
          checklistItems: const [
            ChecklistItem(text: 'durable-task', isChecked: true)
          ]);
      await notes.createNote(
          title: 'Journal',
          content: 'durable-journal',
          journalDate: DateTime.utc(2026, 11, 24),
          tags: ['journal'],
          aliases: ['Daily alias']);
      final archived =
          await notes.createNote(title: 'Archived', content: 'durable-archive');
      await notes.saveNote(archived.copyWith(isArchived: true));
      await vault.createEntry(
          title: 'Password',
          username: 'durable-user',
          password: 'durable-password',
          totpSecret: 'JBSWY3DPEHPK3PXP',
          notes: 'durable-secret-note',
          url: 'https://example.invalid',
          tags: ['login']);
      await ssh.createCredential(
          label: 'Password SSH',
          host: 'ssh.invalid',
          username: 'durable-ssh-user',
          password: 'durable-ssh-password');
      await ssh.createCredential(
          label: 'Key SSH',
          host: 'key.invalid',
          port: 2222,
          username: 'durable-key-user',
          authType: SshAuthType.publicKey,
          privateKey: 'durable-private-key',
          passphrase: 'durable-passphrase');
      await sync.sync();
      await Hive.close();
      await remote.writeAsBytes(f.remote.bytes!, flush: true);
      for (final entry in f.remote.files.entries) {
        final file = File('${sandbox.path}/files/${entry.key}');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(entry.value, flush: true);
      }
      final process = await launch(boundary: boundary, action: 'restore');
      addTearDown(() => process.kill(ProcessSignal.sigkill));
      final errors = process.stderr.transform(utf8.decoder).join();
      final reached = Completer<void>();
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        if (line == 'checkpoint:$boundary' && !reached.isCompleted) {
          reached.complete();
        }
      });
      await reached.future.timeout(const Duration(seconds: 20));
      expect(process.kill(ProcessSignal.sigkill), true);
      expect(await process.exitCode, isNot(0));
      expect(await errors, isNot(contains('process-token')));
      expect(await finish(await launch(action: 'restore')),
          contains('restored:5:1:2'));
      // Reopening after a successful retry must not duplicate the partially
      // restored note or require another approval.
      expect(await finish(await launch(action: 'restore')),
          contains('restored:5:1:2'));
    }, timeout: const Timeout(Duration(minutes: 1)));
  }

  for (final boundary in [
    'before-put',
    'after-put',
    'before-cache',
    'after-cache'
  ]) {
    test('TC-OBS-005/E2E-008 real SIGKILL and disk restart $boundary',
        () async {
      final before = sha256.convert(await remote.readAsBytes()).toString();
      final process = await launch(boundary: boundary);
      addTearDown(() => process.kill(ProcessSignal.sigkill));
      final errors = process.stderr.transform(utf8.decoder).join();
      final reached = Completer<void>();
      final output = <String>[];
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        output.add(line);
        if (line == 'checkpoint:$boundary' && !reached.isCompleted) {
          reached.complete();
        }
      });
      await reached.future.timeout(const Duration(seconds: 20),
          onTimeout: () => throw StateError('Checkpoint missing: $output'));
      expect(process.kill(ProcessSignal.sigkill), true);
      expect(await process.exitCode, isNot(0));
      expect(await errors, isNot(contains('process-token')));
      final committed = sha256.convert(await remote.readAsBytes()).toString();
      expect(committed == before, boundary == 'before-put');
      final result = await finish(await launch());
      expect(result, contains('"result":"trusted"'));
      expect(result, contains('"stale":false'));
      expect(result, contains('"source","target"'));
      expect(result,
          contains(sha256.convert(await remote.readAsBytes()).toString()));
      // One more fresh process proves the retry is idempotent.
      final durable = await remote.readAsBytes();
      expect(await finish(await launch()), contains('"result":"trusted"'));
      expect(await remote.readAsBytes(), durable);
    }, timeout: const Timeout(Duration(minutes: 1)));
  }

  test('TC-OBS-006 real process rejects a legacy optimistic disk cache',
      () async {
    final optimistic = await f.decode();
    (optimistic['pendingDeviceApprovals'] as List).single['status'] =
        'approved';
    await f.edit((registry) {
      final request =
          (registry['pendingDeviceApprovals'] as List).single as Map;
      request['status'] = 'pending';
      request.remove('respondedAt');
      request.remove('respondedByDeviceId');
    });
    await remote.writeAsBytes(f.remote.bytes!, flush: true);
    final before = await remote.readAsBytes();
    expect(
        await finish(
            await launch(action: 'optimistic', cache: jsonEncode(optimistic))),
        contains('seeded'));
    expect(await finish(await launch()), contains('unapproved'));
    expect(await remote.readAsBytes(), before);
  });
}
