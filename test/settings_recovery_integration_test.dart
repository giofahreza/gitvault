import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitvault/core/crypto/key_storage.dart';
import 'package:gitvault/core/providers/providers.dart';
import 'package:gitvault/core/services/foreground_sync_service.dart';
import 'package:gitvault/core/services/github_service.dart';
import 'package:gitvault/data/repositories/notes_repository.dart';
import 'package:gitvault/data/repositories/device_registry_store.dart';
import 'package:gitvault/data/repositories/sync_engine.dart';
import 'package:gitvault/data/repositories/vault_repository.dart';
import 'package:gitvault/features/settings/recovery_approval_dialog.dart';
import 'package:gitvault/features/settings/settings_screen.dart';
import 'package:gitvault/utils/constants.dart';
import 'package:gitvault/utils/mnemonic_helper.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/memory_registry_storage.dart';
import 'support/registry_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late RegistryFixture f;
  late KeyStorage target;
  late MemoryRegistryStorage source;
  var failRestore = false;
  int? restoreError;
  final transientErrors = <String, List<int>>{};
  final observedErrors = <int>[];
  final repositoryErrors = <int>[];

  Future<http.Response> api(http.Request request) async {
    http.Response response(Object json, int status) =>
        http.Response(jsonEncode(json), status, headers: {
          'date': HttpDate.format(DateTime.now().toUtc()),
          'content-type': 'application/json'
        });
    final uri = request.url;
    final token = request.headers['authorization'] ?? '';
    if (token.contains('invalid-test-token')) {
      return response({'message': 'Bad credentials'}, 401);
    }
    if (uri.path == '/repos/fixture-owner/fixture-repo') {
      if (repositoryErrors.isNotEmpty) {
        final status = repositoryErrors.removeAt(0);
        observedErrors.add(status);
        return response({'message': 'Transient repository failure'}, status);
      }
      return response({'size': 1, 'default_branch': 'main'}, 200);
    }
    if (uri.path.contains('/branches/')) {
      return response({'name': Constants.dataBranch}, 200);
    }
    const prefix = '/repos/fixture-owner/fixture-repo/contents/';
    if (!uri.path.startsWith(prefix))
      throw StateError('Unexpected local API path');
    final path = uri.path.substring(prefix.length);
    final queued = transientErrors['${request.method}:$path'];
    if (queued != null && queued.isNotEmpty) {
      final status = queued.removeAt(0);
      observedErrors.add(status);
      return response({'message': 'Transient local test outage'}, status);
    }
    if (request.method == 'GET') {
      if (restoreError != null &&
          path == Constants.indexFile &&
          await target.hasRootKey()) {
        final status = restoreError!;
        restoreError = null;
        observedErrors.add(status);
        return response({'message': 'Transient restore failure'}, status);
      }
      if (path == Constants.indexFile &&
          token.contains('missing-index-token')) {
        return response({'message': 'Not found'}, 404);
      }
      if (failRestore &&
          path == Constants.indexFile &&
          await target.hasRootKey()) {
        return response({'message': 'Local test restore outage'}, 503);
      }
      final bytes = path == Constants.trustedDevicesFile
          ? f.remote.bytes
          : f.remote.files[path];
      return bytes == null
          ? response({'message': 'Not found'}, 404)
          : response({
              'encoding': 'base64',
              'content': base64Encode(bytes),
              'sha': sha256.convert(bytes).toString()
            }, 200);
    }
    if (request.method == 'PUT') {
      final body = jsonDecode(request.body) as Map;
      final bytes = base64Decode(body['content'] as String);
      if (path == Constants.trustedDevicesFile) {
        try {
          final sha = await f.remote.writeFileSnapshot(
              path: path,
              content: bytes,
              expectedSha: body['sha'] as String?,
              commitMessage: 'Test protocol');
          return response({
            'content': {'sha': sha}
          }, 200);
        } on GitHubException catch (e) {
          return response({'message': 'Conflict'}, e.statusCode ?? 500);
        }
      }
      throw StateError('Recovery must not upload vault content');
    }
    throw StateError('Unexpected local API method');
  }

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('settings-recovery-');
    Hive.init(directory.path);
  });
  Future<void> clearVaultBoxes() async {
    for (final box in [
      'notes',
      'vault_entries',
      'sync_metadata',
      'ssh_credentials',
      'secure_keys'
    ]) {
      if (Hive.isBoxOpen(box)) await Hive.box<String>(box).close();
      await Hive.deleteBoxFromDisk(box);
    }
  }

  setUp(() async {
    await clearVaultBoxes();
    f = RegistryFixture();
    await f.seed({'devices': []});
    source = await f.device('source');
    final vault = VaultRepository(cryptoManager: f.crypto, keyStorage: source);
    final notes = NotesRepository(cryptoManager: f.crypto, keyStorage: source);
    final sync = SyncEngine(
        vaultRepository: vault,
        notesRepository: notes,
        githubService: f.remote,
        cryptoManager: f.crypto,
        keyStorage: source);
    await sync.initialize();
    await notes.createNote(
        title: 'Recovered through Settings', content: 'Encrypted body');
    await sync.sync();
    await clearVaultBoxes();
    target = KeyStorage();
    await target.initialize();
    await target.storeDeviceId('target');
    await target.storeLocalDeviceName('Target');
    await target.storeDeviceRegistrationMethod('recovery');
    failRestore = false;
    restoreError = null;
    transientErrors.clear();
    observedErrors.clear();
    repositoryErrors.clear();
    for (final channel in [
      'com.giofahreza.gitvault/ime',
      'be.tramckrijte.workmanager/foreground_channel_work_manager'
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(channel), (_) async => null);
    }
  });
  tearDown(() async {
    ForegroundSyncService.stopPeriodicSync();
    ForegroundSyncService.stopTrustMonitoring();
  });
  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  for (final journey in [
    'approval',
    'restore-failure',
    'new-token',
    'source-reconnect-before-expiry',
    'source-reconnect-after-expiry',
    'intermittent-api',
    'restore-429',
    'restore-500',
    'setup-request-source-429',
    'setup-request-source-500',
  ]) {
    testWidgets('TC-MODAL-001/010/014 actual Settings $journey journey',
        (tester) async {
      final fullFailures = journey.startsWith('setup-request-source-');
      final failureStatus = journey.endsWith('429') ? 429 : 500;
      final sourceVisible = ValueNotifier(false);
      addTearDown(sourceVisible.dispose);
      if (fullFailures) {
        await tester.binding.setSurfaceSize(const Size(1600, 1200));
        addTearDown(() => tester.binding.setSurfaceSize(null));
      }
      Future<void> frames([int count = 8]) async {
        for (var i = 0; i < count; i++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 25)));
          await http.runWithClient(
              () => tester.pump(const Duration(milliseconds: 100)),
              () => MockClient(api));
        }
      }

      Future<void> press(String label) async {
        final button = find.widgetWithText(FilledButton, label);
        expect(button, findsOneWidget);
        final action = tester.widget<FilledButton>(button).onPressed;
        expect(action, isNotNull);
        await tester.runAsync(() async {
          http.runWithClient(action!, () => MockClient(api));
          await Future<void>.delayed(const Duration(milliseconds: 180));
        });
        await frames();
      }

      final requesterApp = ProviderScope(
          overrides: [
            keyStorageProvider.overrideWithValue(target),
            cryptoManagerProvider.overrideWithValue(f.crypto),
          ],
          child: MaterialApp(
              home: Consumer(
                  builder: (context, ref, _) => Scaffold(
                      body: FilledButton(
                          onPressed: () => showGitHubSetupDialog(context, ref,
                              isEditing: false),
                          child: const Text('Connect'))))));
      await tester.pumpWidget(fullFailures
          ? Row(textDirection: TextDirection.ltr, children: [
              Expanded(child: requesterApp),
              Expanded(
                child: ProviderScope(
                  overrides: [
                    keyStorageProvider.overrideWithValue(source),
                    cryptoManagerProvider.overrideWithValue(f.crypto),
                    gitHubServiceFactoryProvider.overrideWithValue((
                            {required accessToken,
                            required repoOwner,
                            required repoName}) =>
                        f.remote),
                  ],
                  child: MaterialApp(
                      home: Scaffold(
                    body: ValueListenableBuilder<bool>(
                      valueListenable: sourceVisible,
                      builder: (_, visible, __) => visible
                          ? const SingleChildScrollView(
                              child: DeviceListSection(isActive: true))
                          : const SizedBox(),
                    ),
                  )),
                ),
              ),
            ])
          : requesterApp);
      await press('Connect');
      Future<void> enter(String label, String value) async {
        final field = find.byWidgetPredicate(
            (w) => w is TextField && w.decoration?.labelText == label);
        await tester.enterText(field, value);
      }

      await enter('GitHub username', 'fixture-owner');
      await enter('Repository name', 'fixture-repo');
      await enter('Access token', 'old-test-token');
      if (fullFailures) {
        final before = f.remote.writes;
        repositoryErrors.add(failureStatus);
        await press('Save & Validate');
        expect(find.text('Connect GitHub Sync'), findsOneWidget);
        expect(find.textContaining('Could not verify GitHub Sync.'),
            findsOneWidget);
        expect(await target.getGitHubToken(), null);
        expect(await target.hasRootKey(), false);
        expect(f.remote.writes, before);
        transientErrors['GET:${Constants.indexFile}'] = [failureStatus];
        await press('Save & Validate');
        expect(find.text('Connect GitHub Sync'), findsOneWidget);
        expect(find.textContaining('Could not verify GitHub Sync.'),
            findsOneWidget);
        expect(await target.getGitHubToken(), null);
        expect(f.remote.writes, before);
      }
      await press('Save & Validate');
      await press('Restore with Recovery Phrase');
      await enter(
          '24-Word Recovery Phrase', MnemonicHelper.rootKeyToMnemonic(f.root));
      if (fullFailures) {
        for (final method in ['GET', 'PUT']) {
          final before = f.remote.writes;
          transientErrors['$method:${Constants.trustedDevicesFile}'] = [
            ...List.filled(
                method == 'PUT' && failureStatus >= 500
                    ? DeviceRegistryStore.maxAttempts
                    : 1,
                failureStatus)
          ];
          await press('Restore');
          expect(find.text('Enter 24-Word Recovery Phrase'), findsOneWidget);
          expect(find.textContaining('Failed:'), findsOneWidget);
          expect(find.byType(RecoveryApprovalDialog), findsNothing);
          expect(await target.hasRootKey(), false);
          expect(await target.getGitHubToken(), null);
          expect(f.remote.writes, before);
          final registry = (await tester.runAsync(f.decode))!;
          expect(registry['pendingDeviceApprovals'] ?? [], isEmpty);
        }
      }
      await press('Restore');
      expect(find.byType(RecoveryApprovalDialog), findsOneWidget);
      final approvals =
          (await tester.runAsync(f.decode))!['pendingDeviceApprovals'] as List;
      var id = (approvals.single as Map)['approvalId'] as String;

      Future<void> checkApproval() async {
        await http.runWithClient(() => tester.tap(find.text('Check Approval')),
            () => MockClient(api));
        await frames();
      }

      if (journey.startsWith('source-reconnect')) {
        f.remote.readError = GitHubException('Offline', kind: 'network');
        await tester.runAsync(() => expectLater(
            f.respond(source, id), throwsA(isA<GitHubException>())));
        await checkApproval();
        expect(find.byType(RecoveryApprovalDialog), findsOneWidget);
        expect(await target.hasRootKey(), false);
        f.remote.readError = null;
        if (journey.endsWith('after-expiry')) {
          await tester.runAsync(() => f.edit((registry) {
                final request =
                    (registry['pendingDeviceApprovals'] as List).single as Map;
                request['expiresAt'] = DateTime.now()
                    .toUtc()
                    .subtract(const Duration(minutes: 1))
                    .toIso8601String();
              }));
          await tester.runAsync(() =>
              expectLater(f.respond(source, id), throwsA(isA<StateError>())));
          await checkApproval();
          expect(find.text('Recovery request expired. Request approval again.'),
              findsOneWidget);
          await http.runWithClient(
              () => tester.tap(find.text('Request Approval Again')),
              () => MockClient(api));
          await frames();
          final requests = (await tester
              .runAsync(f.decode))!['pendingDeviceApprovals'] as List;
          final replacement =
              requests.cast<Map>().singleWhere((r) => r['status'] == 'pending');
          expect(replacement['approvalId'], isNot(id));
          id = replacement['approvalId'] as String;
        }
      }

      if (journey == 'intermittent-api') {
        transientErrors['GET:${Constants.trustedDevicesFile}'] = [429, 500];
        await checkApproval();
        expect(find.text('Temporarily unable to confirm registration.'),
            findsOneWidget);
        await checkApproval();
        expect(await target.hasRootKey(), false);
        await checkApproval();
        expect(find.byType(RecoveryApprovalDialog), findsOneWidget);
        transientErrors['PUT:${Constants.trustedDevicesFile}'] = [429, 500];
      }

      if (journey == 'new-token') {
        await tester.runAsync(() => f.edit((registry) {
              (registry['pendingDeviceApprovals'] as List).single['status'] =
                  'expired';
            }));
        await http.runWithClient(() => tester.pump(const Duration(seconds: 3)),
            () => MockClient(api));
        await frames();
        await tester.tap(find.text('Use New Token'));
        await frames();
        await enter('New GitHub token', 'old-test-token');
        await press('Verify New Token');
        expect(find.text('Use a newly generated token, not the old token.'),
            findsOneWidget);
        final writes = f.remote.writes;
        await enter('New GitHub token', 'invalid-test-token');
        await press('Verify New Token');
        expect(find.textContaining('Failed:'), findsOneWidget);
        expect(f.remote.writes, writes);
        await enter('New GitHub token', 'missing-index-token');
        await press('Verify New Token');
        expect(find.textContaining('no GitVault vault data was found'),
            findsOneWidget);
        expect(f.remote.writes, writes);
        await enter('New GitHub token', 'new-test-token');
        await press('Verify New Token');
      } else {
        failRestore = journey == 'restore-failure';
        restoreError = journey == 'restore-429'
            ? 429
            : journey == 'restore-500'
                ? 500
                : null;
        if (fullFailures) {
          sourceVisible.value = true;
          await frames();
          expect(find.text('Approve'), findsOneWidget);
          for (final method in ['GET', 'PUT']) {
            final before = f.remote.writes;
            if (method == 'GET') {
              f.remote.readError = GitHubException('Source read outage',
                  statusCode: failureStatus);
            } else {
              f.remote.writeError = GitHubException('Source write outage',
                  statusCode: failureStatus);
            }
            await tester.runAsync(() => tester.tap(find.text('Approve')));
            await frames();
            expect(
                find.textContaining('Could not respond to recovery request:'),
                findsOneWidget);
            expect(f.remote.writes, before);
            expect(await target.hasRootKey(), false);
            f.remote.readError = null;
            f.remote.writeError = null;
            final registry = (await tester.runAsync(f.decode))!;
            expect(
                (registry['pendingDeviceApprovals'] as List).single['status'],
                'pending');
            if (method == 'GET') {
              expect(find.text('Approve'), findsNothing);
              await tester.runAsync(
                  () => tester.tap(find.byTooltip('Retry device refresh')));
              await frames();
            }
            expect(find.text('Approve'), findsOneWidget);
          }
          await tester.runAsync(() => tester.tap(find.text('Approve')));
          await frames();
          expect(find.text('Approve'), findsNothing);
          final approvedRegistry = (await tester.runAsync(f.decode))!;
          expect(
              (approvedRegistry['pendingDeviceApprovals'] as List)
                  .single['status'],
              'approved');
          expect(
              observedErrors,
              List.filled(
                  failureStatus >= 500
                      ? 3 + DeviceRegistryStore.maxAttempts
                      : 4,
                  failureStatus));
          expect(transientErrors.values.every((q) => q.isEmpty), true);
        } else {
          await tester.runAsync(() => f.respond(source, id));
        }
        await http.runWithClient(() => tester.pump(const Duration(seconds: 3)),
            () => MockClient(api));
        await frames(20);
        if (journey == 'intermittent-api') {
          // The approval is durable, but registration must wait for a PUT
          // confirmation. A retry must not rotate the token or trust cache.
          expect(find.byType(RecoveryApprovalDialog), findsOneWidget);
          expect(await target.hasRootKey(), false);
          for (var i = 0;
              i < 4 &&
                  find.byType(RecoveryApprovalDialog).evaluate().isNotEmpty;
              i++) {
            await checkApproval();
          }
          expect(observedErrors, [429, 500, 429, 500]);
          expect(transientErrors.values.every((q) => q.isEmpty), true);
        }
      }
      for (var i = 0;
          i < 100 && find.byType(RecoveryApprovalDialog).evaluate().isNotEmpty;
          i++) {
        await frames(1);
      }
      expect(find.byType(RecoveryApprovalDialog), findsNothing);
      for (var i = 0;
          i < 100 &&
              find.textContaining('Vault restored!').evaluate().isEmpty &&
              find
                  .textContaining('Recovery completed, but sync failed:')
                  .evaluate()
                  .isEmpty;
          i++) {
        await frames(1);
      }
      expect(await target.getGitHubToken(),
          journey == 'new-token' ? 'new-test-token' : 'old-test-token');
      expect(
          await target.getDeviceRegistrationMethod(),
          journey == 'new-token'
              ? 'recovery_token_rotated'
              : 'recovery_approved');
      expect(await target.getRootKey(), f.root);
      final registered = (await tester.runAsync(f.decode))!['devices'] as List;
      expect(registered, contains(containsPair('deviceId', 'target')));
      if (journey == 'restore-failure' ||
          journey == 'restore-429' ||
          journey == 'restore-500') {
        expect(find.textContaining('Recovery completed, but sync failed:'),
            findsOneWidget);
        expect(find.textContaining('Try "Sync Now"'), findsOneWidget);
        failRestore = false;
        final retried = await tester.runAsync(() => http.runWithClient(
            () => ForegroundSyncService.restoreFromGitHubNow(
                reason: 'Local retry'),
            () => MockClient(api)));
        await frames();
        expect(retried?.pulled, 1);
        expect(ForegroundSyncService.lastError, null);
      } else {
        expect(find.text('Vault restored! Pulled 1 item from GitHub.'),
            findsOneWidget);
      }
      final notes =
          NotesRepository(cryptoManager: f.crypto, keyStorage: target);
      await tester.runAsync(notes.initialize);
      expect((await tester.runAsync(notes.getAllStoredNotes))!.single.content,
          'Encrypted body');
      expect(tester.takeException(), null);
      await tester.pumpWidget(const SizedBox());
      await frames();
    });
  }
}
