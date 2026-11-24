import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitvault/core/auth/pin_auth.dart';
import 'package:gitvault/core/crypto/crypto_manager.dart';
import 'package:gitvault/core/crypto/key_storage.dart';
import 'package:gitvault/core/providers/providers.dart';
import 'package:gitvault/core/services/foreground_sync_service.dart';
import 'package:gitvault/core/session/vault_session_controller.dart';
import 'package:gitvault/features/settings/settings_screen.dart';
import 'package:gitvault/main.dart' show BiometricGate, ForegroundSyncScope;
import 'package:gitvault/mcp/mcp_models.dart';
import 'package:gitvault/mcp/mcp_providers.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:mcp_dart/mcp_dart.dart' as mcp;

import '../support/registry_fixture.dart';

class _HookTransport extends mcp.Transport {
  late _HookTransport peer;
  @override
  String? get sessionId => null;
  @override
  Future<void> start() async {}
  @override
  Future<void> send(mcp.JsonRpcMessage message, {int? relatedRequestId}) async {
    scheduleMicrotask(() => peer.onmessage?.call(message));
  }

  @override
  Future<void> close() async {
    onclose?.call();
  }
}

class _SwitchablePin extends PinAuth {
  bool configured = false;
  _SwitchablePin(KeyStorage storage) : super(keyStorage: storage);
  @override
  Future<bool> isPinSetup() async => configured;
}

class _HookCrypto extends CryptoManager {
  String? phase;
  final reached = Completer<void>();
  final release = Completer<void>();

  Future<void> hold(String boundary) async {
    if (phase == boundary && !reached.isCompleted) {
      reached.complete();
      await release.future;
    }
  }

  @override
  Future<EncryptedBox> encryptXChaCha20(
      {required Uint8List data, required Uint8List key}) async {
    final result = await super.encryptXChaCha20(data: data, key: key);
    await hold('encrypt');
    return result;
  }

  @override
  Future<Uint8List> decryptXChaCha20(
      {required EncryptedBox box, required Uint8List key}) async {
    final result = await super.decryptXChaCha20(box: box, key: key);
    await hold('decrypt');
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final action in [
    'wipe',
    'device-revocation',
    'timeout',
    'quit',
    'duress'
  ]) {
    for (final phase in ['approval', 'encrypt', 'decrypt', 'queued-delete']) {
      final operations = phase == 'queued-delete'
          ? ['delete']
          : phase == 'decrypt'
              ? [
                  'list',
                  'search',
                  'get',
                  'tags',
                  'link',
                  'backlinks',
                  'outline',
                  'block',
                  'resource'
                ]
              : [
                  'create',
                  'append',
                  'edit',
                  'section',
                  'daily-create',
                  'daily-append-new',
                  'daily-append-existing',
                  'archive',
                  if (phase == 'approval') 'delete'
                ];
      for (final operation in operations) {
        testWidgets(
            'MCP-GAP-004/012 actual app $action rejects $operation at $phase',
            (tester) async {
          late Directory directory;
          late KeyStorage storage;
          late ProviderContainer container;
          late RegistryFixture f;
          late String id;
          late _SwitchablePin pin;
          late _HookCrypto crypto;
          late String noteId;
          late String version;
          String? dailyVersion;
          late Map<dynamic, String> before;
          var cleaned = false;
          await tester.runAsync(() async {
            PackageInfo.setMockInitialValues(
                appName: 'GitVault',
                packageName: 'com.giofahreza.gitvault',
                version: 'test',
                buildNumber: '1',
                buildSignature: 'test');
            directory = await Directory.systemTemp.createTemp('mcp-hook-');
            Hive.init(directory.path);
            f = RegistryFixture();
            await f.seed({
              'devices': [],
              'revokedDevices': [
                {'deviceId': 'target'}
              ]
            });
            storage = KeyStorage();
            await storage.initialize();
            await storage.storeRootKey(f.root);
            await storage.storeDeviceId('target');
            await storage.storeLocalDeviceName('Target');
            pin = _SwitchablePin(storage);
            crypto = _HookCrypto();
            container = ProviderContainer(overrides: [
              keyStorageProvider.overrideWithValue(storage),
              cryptoManagerProvider.overrideWithValue(crypto),
              pinAuthProvider.overrideWithValue(pin),
              biometricEnabledProvider.overrideWith((ref) => false),
              authLockTimeoutSecondsProvider.overrideWith((ref) => 0),
            ]);
            final registry = container.read(mcpClientRegistryProvider);
            await registry.setEnabled(true);
            id = (await registry.createClient(
                    displayName: 'Pending writer',
                    transport: McpClientTransport.streamableHttp,
                    permissions: McpPermission.values.toSet(),
                    writePolicy: phase == 'approval'
                        ? McpWritePolicy.askEveryTime
                        : McpWritePolicy.allowWhileUnlocked))
                .client
                .id;
            // Establish the production provider listener without starting an OS
            // listener or modifying the user's MCP discovery directory.
            container.read(mcpDesktopServerProvider);
            container.read(vaultSessionProvider.notifier).unlock();
            {
              final repository = container.read(notesRepositoryProvider);
              await repository.initialize();
              noteId = (await repository.createNote(
                      title: 'Existing note',
                      content: '# Heading\nhook-body-canary ^block1'))
                  .uuid;
              version = (await repository.getNote(noteId))!
                  .modifiedAt
                  .toUtc()
                  .toIso8601String();
              if (operation == 'daily-append-existing') {
                dailyVersion = (await repository.createNote(
                        title: 'Daily',
                        content: 'Original daily',
                        journalDate: DateTime.utc(2026, 11, 23)))
                    .modifiedAt
                    .toUtc()
                    .toIso8601String();
              }
              before = Map.of(Hive.box<String>('notes').toMap());
            }
            if (action == 'duress') {
              await container
                  .read(duressManagerProvider)
                  .setupDuressMode(pin: '654321');
            }
            for (final channel in [
              'com.giofahreza.gitvault/ime',
              'be.tramckrijte.workmanager/foreground_channel_work_manager',
              'window_manager',
            ]) {
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                  .setMockMethodCallHandler(
                      MethodChannel(channel), (_) async => null);
            }
          });
          addTearDown(() => tester.runAsync(() async {
                if (cleaned) return;
                if (!crypto.release.isCompleted) crypto.release.complete();
                ForegroundSyncService.stopPeriodicSync();
                ForegroundSyncService.stopTrustMonitoring();
                container.dispose();
                await Hive.close().timeout(const Duration(seconds: 5));
                await directory.delete(recursive: true);
              }));
          Future<void> frames([int count = 10]) async {
            for (var i = 0; i < count; i++) {
              await tester.runAsync(
                  () => Future<void>.delayed(const Duration(milliseconds: 20)));
              await tester.pump(const Duration(milliseconds: 50));
            }
          }

          await tester.pumpWidget(UncontrolledProviderScope(
              container: container,
              child: MaterialApp(
                  home: action == 'wipe'
                      ? const SettingsScreen(isActive: false)
                      : action == 'timeout' ||
                              action == 'quit' ||
                              action == 'duress'
                          ? const BiometricGate()
                          : const ForegroundSyncScope(
                              child: Scaffold(body: Text('Unlocked'))))));
          await frames();
          expect(container.read(vaultSessionProvider).canAccessVault, true);
          // Do not configure remote sync until after ForegroundSyncScope starts;
          // the explicit check below is the event driving revocation.
          if (action == 'device-revocation') {
            await tester.runAsync(() => storage.storeGitHubCredentials(
                token: 'hook-token', repoOwner: 'owner', repoName: 'repo'));
          }
          final service = container.read(notesMcpServiceProvider);
          late Future<dynamic> write;
          mcp.McpClient? resourceClient;
          mcp.McpServer? resourceServer;
          Future<void>? holder;
          var holderDone = false;
          var deleteApproved = false;
          late Future<void> rejected;
          var resolved = false;
          await tester.runAsync(() async {
            if (operation == 'resource') {
              resourceServer = container
                  .read(gitVaultMcpServerFactoryProvider)
                  .createForClient(id);
              final left = _HookTransport(), right = _HookTransport();
              left.peer = right;
              right.peer = left;
              resourceClient = mcp.McpClient(const mcp.Implementation(
                  name: 'hook-resource', version: '1'));
              await resourceServer!.connect(left);
              await resourceClient!.connect(right);
            }
            crypto.phase = phase == 'queued-delete' ? 'encrypt' : phase;
            if (phase == 'queued-delete') {
              final controller = container.read(mcpApprovalControllerProvider);
              controller.addListener(() {
                final request = controller.nextRequest;
                if (request != null) {
                  deleteApproved = true;
                  controller.resolve(request.id, McpApprovalDecision.allowOnce);
                }
              });
              final repository = container.read(notesRepositoryProvider);
              final original = (await repository.getNote(noteId))!;
              holder = repository.saveNote(original);
              holder!.then((_) => holderDone = true);
            }
            write = switch (operation) {
              'list' => service.listNotes(clientId: id),
              'search' => service.searchNotes(clientId: id, query: 'Existing'),
              'get' => service.getNote(clientId: id, noteId: noteId),
              'tags' => service.listNoteTags(clientId: id),
              'link' =>
                service.resolveNoteLink(clientId: id, query: 'Existing note'),
              'backlinks' =>
                service.listBacklinks(clientId: id, noteId: noteId),
              'outline' => service.getNoteOutline(clientId: id, noteId: noteId),
              'block' =>
                service.resolveBlockReference(clientId: id, blockId: 'block1'),
              'resource' => resourceClient!.readResource(
                  mcp.ReadResourceRequest(uri: 'gitvault://notes/$noteId')),
              'append' => service.appendToNote(
                  clientId: id,
                  noteId: noteId,
                  expectedModifiedAt: version,
                  text: 'Append'),
              'edit' => service.updateNote(
                  clientId: id,
                  noteId: noteId,
                  expectedModifiedAt: version,
                  content: 'Changed'),
              'section' => service.updateNoteSection(
                  clientId: id,
                  noteId: noteId,
                  expectedModifiedAt: version,
                  heading: 'Heading',
                  content: 'Changed'),
              'daily-create' => service.getOrCreateDailyNote(
                  clientId: id, date: '2026-11-23', template: 'New daily'),
              'daily-append-new' ||
              'daily-append-existing' =>
                service.appendToDailyNote(
                    clientId: id,
                    date: '2026-11-23',
                    text: 'Append',
                    expectedModifiedAt: dailyVersion),
              'archive' => service.archiveNote(
                  clientId: id, noteId: noteId, expectedModifiedAt: version),
              'delete' => service.deleteNote(
                  clientId: id, noteId: noteId, expectedModifiedAt: version),
              _ => service.createNote(
                  clientId: id,
                  title: 'Must not persist',
                  content: 'hook-body-canary'),
            };
            rejected = expectLater(
                write,
                throwsA(operation == 'resource'
                    ? isA<mcp.McpError>()
                    : isA<McpOperationException>()));
            rejected.then((_) => resolved = true);
          });
          await frames();
          if (phase != 'approval') {
            for (var i = 0; i < 100 && !crypto.reached.isCompleted; i++) {
              await frames(1);
            }
            expect(crypto.reached.isCompleted, true,
                reason: 'The operation must reach the actual crypto boundary');
          }
          final approvals = container.read(mcpApprovalControllerProvider);
          expect(approvals.pending, hasLength(phase == 'approval' ? 1 : 0));
          if (phase == 'queued-delete') expect(deleteApproved, true);
          if (action == 'wipe') {
            await tester.scrollUntilVisible(find.text('Wipe All Data'), 400,
                scrollable: find.byType(Scrollable).first);
            await tester.runAsync(() => tester.tap(find.text('Wipe All Data')));
            await frames();
            await tester.enterText(
                find.widgetWithText(TextField, 'Confirmation'), 'WIPE');
            await frames(2);
            await tester
                .runAsync(() => tester.tap(find.text('Wipe Everything')));
          } else if (action == 'device-revocation') {
            await tester.runAsync(() => http.runWithClient(
                () => ForegroundSyncService.checkTrustNow(
                    reason: 'App hook test', force: true),
                () => MockClient((request) async => http.Response(
                        jsonEncode({
                          'encoding': 'base64',
                          'content': base64Encode(f.remote.bytes!),
                          'sha': f.remote.sha,
                        }),
                        200,
                        headers: {
                          'date': HttpDate.format(DateTime.now().toUtc())
                        }))));
          } else if (action == 'quit') {
            pin.configured = true;
            await tester.runAsync(() =>
                container.read(desktopLifecycleServiceProvider).requestQuit());
          } else {
            pin.configured = true;
            tester.binding
                .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
          }
          await frames(20);
          if (action == 'duress') {
            tester.binding
                .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
            await frames();
            expect(find.text('Enter PIN'), findsOneWidget);
            for (final digit in ['6', '5', '4', '3', '2', '1']) {
              await tester.tap(find.text(digit));
              await frames(1);
            }
            // Six digits submit the actual PIN UI automatically; production
            // Argon2 and key erasure run without a mocked duress manager.
            for (var i = 0;
                i < 300 &&
                    container.read(vaultSessionProvider).status !=
                        VaultSessionStatus.duress;
                i++) {
              await frames(1);
            }
            expect(container.read(vaultSessionProvider).status,
                VaultSessionStatus.duress);
            expect(await storage.hasRootKey(), false);
          }
          expect(container.read(vaultSessionProvider).canAccessVault, false,
              reason:
                  'The application hook must lock before resolving the write');
          expect(approvals.pending, isEmpty);
          if (!crypto.release.isCompleted) crypto.release.complete();
          if (action == 'timeout' || action == 'quit') {
            expect(find.text('AI app request'), findsNothing,
                reason:
                    'Approval previews must disappear when the vault locks');
          }
          for (var i = 0; i < 100 && !resolved; i++) {
            await frames(1);
          }
          expect(resolved, true);
          await tester.runAsync(() => rejected);
          if (holder != null) {
            for (var i = 0; i < 100 && !holderDone; i++) {
              await frames(1);
            }
            expect(holderDone, true);
            await tester.runAsync(() => holder!);
          }
          await tester.runAsync(() async {
            await resourceClient?.close();
            await resourceServer?.close();
          });
          expect(approvals.pending, isEmpty);
          expect(container.read(vaultSessionProvider).canAccessVault, false);
          if (action == 'wipe') {
            expect(await storage.hasRootKey(), false);
            expect(container.read(vaultSessionProvider).reason,
                'Vault data was wiped');
          } else if (action == 'device-revocation') {
            expect(container.read(vaultSessionProvider).status,
                VaultSessionStatus.revoked);
            expect(await storage.getGitHubToken(), null);
          } else if (action != 'duress') {
            expect(
                container.read(vaultSessionProvider).reason,
                action == 'quit'
                    ? 'Application is quitting'
                    : 'Authentication required');
            if (action == 'timeout') {
              tester.binding
                  .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
              await frames();
            }
          }
          if (Hive.isBoxOpen('notes')) {
            if (phase == 'queued-delete') {
              // A legitimate local re-save held the queue. Its ciphertext may
              // change, but the queued MCP delete must preserve the note.
              expect(
                  Hive.box<String>('notes').keys.toSet(), before.keys.toSet());
              expect(Hive.box<String>('notes').containsKey(noteId), true);
            } else {
              expect(Hive.box<String>('notes').toMap(), before);
            }
          }
          expect(tester.takeException(), null);
          await tester.runAsync(() => tester.pumpWidget(const SizedBox()));
          await frames();
          late Future<void> closing;
          var closed = false;
          await tester.runAsync(() async {
            ForegroundSyncService.stopPeriodicSync();
            ForegroundSyncService.stopTrustMonitoring();
            container.dispose();
            closing = Hive.close();
            closing.then((_) => closed = true);
          });
          for (var i = 0; i < 100 && !closed; i++) {
            await frames(1);
          }
          expect(closed, true);
          await tester.runAsync(() async {
            await closing;
            await directory.delete(recursive: true);
            cleaned = true;
          });
        });
      }
    }
  }
}
