import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:gitvault/core/crypto/crypto_manager.dart';
import 'package:gitvault/core/crypto/key_storage.dart';
import 'package:gitvault/core/services/github_service.dart';
import 'package:gitvault/data/repositories/sync_engine.dart';
import 'package:gitvault/data/models/note.dart';
import 'package:gitvault/data/repositories/notes_repository.dart';
import 'package:gitvault/data/repositories/vault_repository.dart';
import 'package:gitvault/data/repositories/ssh_repository.dart';
import 'package:gitvault/data/models/vault_entry.dart';
import 'package:gitvault/data/models/ssh_credential.dart';
import 'package:hive/hive.dart';

// The standalone Flutter engine has no IME plugin. Acknowledge only its cache
// notification; all repository encryption, Hive writes and reads remain real.
class _ProbeBinding extends WidgetsFlutterBinding {
  @override
  BinaryMessenger createBinaryMessenger() =>
      _ProbeMessenger(super.createBinaryMessenger());
}

class _ProbeMessenger implements BinaryMessenger {
  final BinaryMessenger delegate;
  _ProbeMessenger(this.delegate);
  @override
  Future<ByteData?>? send(String channel, ByteData? message) => channel ==
          'com.giofahreza.gitvault/ime'
      ? Future.value(const StandardMethodCodec().encodeSuccessEnvelope(null))
      : delegate.send(channel, message);
  @override
  void setMessageHandler(String channel, MessageHandler? handler) =>
      delegate.setMessageHandler(channel, handler);
  @override
  Future<void> handlePlatformMessage(String channel, ByteData? data,
      PlatformMessageResponseCallback? callback) async {
    ServicesBinding.instance.channelBuffers
        .push(channel, data, callback ?? (_) {});
  }
}

String get boundary => Platform.environment['GITVAULT_PROBE_BOUNDARY'] ?? '';
Future<void> checkpoint(String name) async {
  if (boundary != name) return;
  stdout.writeln('checkpoint:$name');
  await stdout.flush();
  await Completer<void>().future;
}

class _DiskRemote extends GitHubService {
  final File remote;
  _DiskRemote(this.remote)
      : super(
            accessToken: 'process-token', repoOwner: 'owner', repoName: 'repo');
  @override
  Future<RemoteFileSnapshot> readFileSnapshot(String path) async {
    final bytes = await remote.readAsBytes();
    return RemoteFileSnapshot(
        bytes: bytes,
        sha: sha256.convert(bytes).toString(),
        serverTime: DateTime.utc(2030));
  }

  @override
  Future<Uint8List?> downloadFile(String path) async {
    final file = File('${remote.parent.path}/files/$path');
    return await file.exists() ? file.readAsBytes() : null;
  }

  @override
  Future<String> writeFileSnapshot(
      {required String path,
      required Uint8List content,
      required String? expectedSha,
      required String commitMessage}) async {
    await checkpoint('before-put');
    if (sha256.convert(await remote.readAsBytes()).toString() != expectedSha) {
      throw GitHubException('Conflict', statusCode: 409);
    }
    final pending = File('${remote.path}.pending');
    await pending.writeAsBytes(content, flush: true);
    await pending.rename(remote.path);
    await checkpoint('after-put');
    return sha256.convert(content).toString();
  }
}

class _DiskStorage extends KeyStorage {
  @override
  Future<void> storeGitHubCredentials(
      {required String token,
      required String repoOwner,
      required String repoName}) async {
    await checkpoint('before-credentials');
    await super.storeGitHubCredentials(
        token: token, repoOwner: repoOwner, repoName: repoName);
    await Hive.box<String>('secure_keys').flush();
    await checkpoint('after-credentials');
  }

  @override
  Future<void> storeRootKey(Uint8List key) async {
    await checkpoint('before-key');
    await super.storeRootKey(key);
    await Hive.box<String>('secure_keys').flush();
    await checkpoint('after-key');
  }

  @override
  Future<void> storeDeviceRegistrySnapshot(String value) async {
    final registry = (jsonDecode(value) as Map)['registry'] as Map;
    final committed = ((registry['devices'] as List?) ?? []).any((d) =>
        d['deviceId'] == 'target' &&
        d['registrationMethod'] == 'recovery_approved');
    if (committed) await checkpoint('before-cache');
    await super.storeDeviceRegistrySnapshot(value);
    // Flush Hive, so the parent can distinguish a completed disk write from
    // a value still held only in this process's memory.
    await Hive.box<String>('secure_keys').flush();
    if (committed) await checkpoint('after-cache');
  }
}

class _CheckpointNotes extends NotesRepository {
  _CheckpointNotes(KeyStorage storage)
      : super(cryptoManager: CryptoManager(), keyStorage: storage);
  @override
  Future<bool> saveNoteIfNewer(Note note) async {
    final saved = await super.saveNoteIfNewer(note);
    await Hive.box<String>('notes').flush();
    if (saved) await checkpoint('during-restore');
    return saved;
  }
}

class _CheckpointVault extends VaultRepository {
  _CheckpointVault(KeyStorage storage)
      : super(cryptoManager: CryptoManager(), keyStorage: storage);
  @override
  Future<void> saveEntry(VaultEntry entry) async {
    await super.saveEntry(entry);
    await Hive.box<String>('vault_entries').flush();
    await checkpoint('after-vault-restore');
  }
}

class _CheckpointSsh extends SshRepository {
  _CheckpointSsh(KeyStorage storage)
      : super(cryptoManager: CryptoManager(), keyStorage: storage);
  @override
  Future<void> saveCredential(SshCredential credential) async {
    await super.saveCredential(credential);
    await Hive.box<String>('ssh_credentials').flush();
    await checkpoint('after-ssh-restore');
  }
}

Future<void> main() async {
  _ProbeBinding();
  final keepAlive = Timer.periodic(const Duration(seconds: 1), (_) {});
  final env = Platform.environment;
  Hive.init(env['GITVAULT_PROBE_LOCAL']!);
  final root = base64Decode(env['GITVAULT_PROBE_ROOT']!);
  final remote = _DiskRemote(File(env['GITVAULT_PROBE_REMOTE']!));
  final storage = _DiskStorage();
  try {
    await storage.initialize();
    await storage.storeDeviceId('target');
    await storage.storeLocalDeviceName('Target');
    await storage.storeDeviceRegistrationMethod('recovery');
    await storage.storeGitHubCredentials(
        token: 'process-token', repoOwner: 'owner', repoName: 'repo');
    if (env['GITVAULT_PROBE_ACTION'] == 'optimistic') {
      // A legacy optimistic cache is persisted separately from the actual
      // pending authority. A fresh process must consult the authority.
      await storage.storeDeviceRegistry(env['GITVAULT_PROBE_CACHE']!);
      await Hive.box<String>('secure_keys').flush();
      stdout.writeln('seeded');
    } else {
      final status = await SyncEngine.getDeviceApprovalStatus(
          keyStorage: storage,
          cryptoManager: CryptoManager(),
          githubService: remote,
          rootKey: root,
          approvalId: 'request');
      if (!status.isApproved) {
        stdout.writeln('unapproved');
      } else {
        await SyncEngine.completeApprovedRecovery(
            keyStorage: storage,
            cryptoManager: CryptoManager(),
            githubService: remote,
            rootKey: root,
            approvalId: 'request');
        await checkpoint('after-registration');
        if (env['GITVAULT_PROBE_ACTION'] == 'restore') {
          await storage.storeRootKey(root);
          await storage.storeDeviceRegistrationMethod('recovery_approved');
          await checkpoint('before-restore');
          final notes = _CheckpointNotes(storage);
          final vault = _CheckpointVault(storage);
          final ssh = _CheckpointSsh(storage);
          final sync = SyncEngine(
              vaultRepository: vault,
              notesRepository: notes,
              sshRepository: ssh,
              githubService: remote,
              cryptoManager: CryptoManager(),
              keyStorage: storage);
          await sync.initialize();
          await sync.restoreFromGitHub();
          await checkpoint('after-restore');
          final restored = await notes.getAllStoredNotes();
          final byTitle = {for (final note in restored) note.title: note};
          final entries = await vault.getAllEntries();
          final credentials = await ssh.getAllCredentials();
          if (restored.length != 5 ||
              byTitle['Durable 0']?.content != 'durable-note-0' ||
              byTitle['Durable 1']?.content != 'durable-note-1' ||
              byTitle['Checklist']?.markdownContent != '- [x] durable-task' ||
              byTitle['Journal']?.journalDate != DateTime.utc(2026, 11, 24) ||
              byTitle['Journal']?.aliases.single != 'Daily alias' ||
              byTitle['Archived']?.isArchived != true ||
              entries.length != 1 ||
              entries.single.password != 'durable-password' ||
              entries.single.totpSecret != 'JBSWY3DPEHPK3PXP' ||
              entries.single.notes != 'durable-secret-note' ||
              credentials.length != 2 ||
              credentials
                      .singleWhere((c) => c.authType == SshAuthType.password)
                      .password !=
                  'durable-ssh-password' ||
              credentials
                      .singleWhere((c) => c.authType == SshAuthType.publicKey)
                      .privateKey !=
                  'durable-private-key' ||
              credentials
                      .singleWhere((c) => c.authType == SshAuthType.publicKey)
                      .passphrase !=
                  'durable-passphrase') {
            throw StateError('Restored notes missing or corrupted');
          }
          stdout.writeln('restored:5:1:2');
        }
        final cache =
            jsonDecode((await storage.getDeviceRegistrySnapshot())!) as Map;
        stdout.writeln(jsonEncode({
          'result': 'trusted',
          'cacheSha': cache['sha'],
          'stale': cache['stale'],
          'devices': (cache['registry']['devices'] as List)
              .map((d) => d['deviceId'])
              .toList()
        }));
      }
    }
  } catch (error) {
    stderr.writeln('probe-error:$error');
    exitCode = 1;
  } finally {
    remote.dispose();
    await Hive.close();
    keepAlive.cancel();
  }
  await stdout.flush();
  await stderr.flush();
  exit(exitCode);
}
