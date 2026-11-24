import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitvault/core/crypto/key_storage.dart';
import 'package:gitvault/core/services/foreground_sync_service.dart';
import 'package:gitvault/core/session/vault_session_controller.dart';
import 'package:gitvault/data/repositories/notes_repository.dart';
import 'package:gitvault/data/repositories/sync_engine.dart';
import 'package:gitvault/data/repositories/vault_repository.dart';
import 'package:gitvault/mcp/mcp_approval_controller.dart';
import 'package:gitvault/mcp/mcp_client_registry.dart';
import 'package:gitvault/mcp/mcp_models.dart';
import 'package:gitvault/mcp/notes_mcp_service.dart';
import 'package:gitvault/utils/constants.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/registry_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'MCP-GAP-010 real debounced foreground sync retries offline encrypted edits',
      () async {
    final directory = await Directory.systemTemp.createTemp('mcp-sync-');
    Hive.init(directory.path);
    final f = RegistryFixture();
    await f.seed({'devices': []});
    final storage = KeyStorage();
    await storage.initialize();
    await storage.storeRootKey(f.root);
    await storage.storeDeviceId('source');
    await storage.storeDeviceRegistrationMethod('setup');
    await storage.storeGitHubCredentials(
        token: 'token-canary',
        repoOwner: 'fixture-owner',
        repoName: 'fixture-repo');
    final repository =
        NotesRepository(cryptoManager: f.crypto, keyStorage: storage);
    final registry = McpClientRegistry();
    final approvals = McpApprovalController();
    addTearDown(() async {
      ForegroundSyncService.stopPeriodicSync();
      ForegroundSyncService.stopTrustMonitoring();
      approvals.dispose();
      registry.dispose();
      await Hive.close();
      await directory.delete(recursive: true);
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel(
                'be.tramckrijte.workmanager/foreground_channel_work_manager'),
            (_) async => null);
    await registry.setEnabled(true);
    final issued = await registry.createClient(
        displayName: 'Offline writer',
        transport: McpClientTransport.streamableHttp,
        permissions: {McpPermission.create},
        writePolicy: McpWritePolicy.allowWhileUnlocked);
    final service = NotesMcpService(
        notesRepository: repository,
        registry: registry,
        approvalController: approvals,
        readSession: () => VaultSessionState(
            status: VaultSessionStatus.unlocked,
            changedAt: DateTime.now(),
            generation: 1));
    var online = false;
    var requests = 0;
    var failedSyncs = 0;
    final revision = ForegroundSyncService.syncRevision.value;
    Future<http.Response> api(http.Request request) async {
      requests++;
      http.Response respond(Object value, int status) =>
          http.Response(jsonEncode(value), status, headers: {
            'content-type': 'application/json',
            'date': HttpDate.format(DateTime.now().toUtc()),
          });
      if (!online) {
        failedSyncs++;
        return respond({'message': 'Offline'}, 503);
      }
      if (request.url.path == '/repos/fixture-owner/fixture-repo') {
        return respond({'size': 1}, 200);
      }
      if (request.url.path.contains('/branches/')) {
        return respond({'name': Constants.dataBranch}, 200);
      }
      const prefix = '/repos/fixture-owner/fixture-repo/contents/';
      if (!request.url.path.startsWith(prefix)) {
        throw StateError('Unexpected GitHub route');
      }
      final path = request.url.path.substring(prefix.length);
      final bytes = path == Constants.trustedDevicesFile
          ? f.remote.bytes
          : f.remote.files[path];
      if (request.method == 'GET') {
        return bytes == null
            ? respond({'message': 'Not found'}, 404)
            : respond({
                'encoding': 'base64',
                'content': base64Encode(bytes),
                'sha': sha256.convert(bytes).toString()
              }, 200);
      }
      if (request.method == 'PUT') {
        final body = jsonDecode(request.body) as Map;
        final uploaded = base64Decode(body['content'] as String);
        String sha;
        if (path == Constants.trustedDevicesFile) {
          sha = await f.remote.writeFileSnapshot(
              path: path,
              content: uploaded,
              expectedSha: body['sha'] as String?,
              commitMessage: 'Protocol');
        } else {
          sha = await f.remote.uploadFile(path: path, content: uploaded);
        }
        return respond({
          'content': {'sha': sha}
        }, 200);
      }
      throw StateError('Unexpected method');
    }

    Future<void> until(bool Function() predicate) async {
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (!predicate() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(predicate(), true);
    }

    await http.runWithClient(() async {
      for (var i = 0; i < 3; i++) {
        await service.createNote(
            clientId: issued.client.id,
            title: 'Offline $i',
            content: 'body-canary-$i');
      }
      expect(requests, 0, reason: 'Writes must be debounced');
      expect((await repository.getAllStoredNotes()).length, 3);
      await until(() => ForegroundSyncService.lastError != null);
      final afterFailure = requests;
      expect(failedSyncs, greaterThan(0));
      expect(f.remote.vaultUploads, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 1300));
      expect(requests, afterFailure, reason: 'One burst schedules one sync');
      online = true;
      await service.createNote(
          clientId: issued.client.id,
          title: 'Reconnect',
          content: 'body-canary-reconnected');
      await until(() => ForegroundSyncService.syncRevision.value > revision);
      expect(ForegroundSyncService.lastError, null);
      expect(ForegroundSyncService.lastResult!.pushed, 4);
      expect(f.remote.files.containsKey(Constants.indexFile), true);
      for (final bytes in f.remote.files.values) {
        expect(utf8.decode(bytes, allowMalformed: true),
            isNot(contains('body-canary')));
      }
      // Discard the local notes and pull through real decryption, proving that
      // all offline edits reached the remote encrypted snapshot.
      await repository.close();
      await Hive.deleteBoxFromDisk('notes');
      final restored =
          NotesRepository(cryptoManager: f.crypto, keyStorage: storage);
      final sync = SyncEngine(
          vaultRepository:
              VaultRepository(cryptoManager: f.crypto, keyStorage: storage),
          notesRepository: restored,
          githubService: f.remote,
          cryptoManager: f.crypto,
          keyStorage: storage);
      await sync.initialize();
      expect((await sync.restoreFromGitHub()).pulled, 4);
      expect(
          (await restored.getAllStoredNotes()).map((n) => n.content).toSet(), {
        'body-canary-0',
        'body-canary-1',
        'body-canary-2',
        'body-canary-reconnected'
      });
    }, () => MockClient(api));
  }, timeout: const Timeout(Duration(minutes: 1)));
}
