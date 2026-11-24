import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitvault/core/crypto/blind_handshake.dart';
import 'package:gitvault/core/providers/providers.dart';
import 'package:gitvault/data/repositories/notes_repository.dart';
import 'package:gitvault/data/repositories/sync_engine.dart';
import 'package:gitvault/data/repositories/vault_repository.dart';
import 'package:gitvault/features/device_linking/link_device_screen.dart';
import 'package:gitvault/features/settings/recovery_approval_dialog.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:hive/hive.dart';

import 'support/memory_registry_storage.dart';
import 'support/registry_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late RegistryFixture f;
  late MemoryRegistryStorage storage;
  late LinkingPayload payload;
  bool? closed;
  Directory? directory;

  setUpAll(() async {
    if (!kIsWeb) {
      directory = await Directory.systemTemp.createTemp('gitvault-link-test-');
      Hive.init(directory!.path);
    }
  });
  tearDownAll(() async {
    await Hive.close();
    if (directory != null) await directory!.delete(recursive: true);
  });

  Future<void> settle(WidgetTester tester) async {
    // Argon2 runs asynchronously; allow its real work to progress as well as
    // widget frames, without replacing PIN verification with a mock.
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 180)));
    for (var frame = 0; frame < 6; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  setUp(() async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('com.giofahreza.gitvault/ime'), (_) async => null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('dev.steenbakker.mobile_scanner/scanner/event'),
        (_) async => null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('dev.steenbakker.mobile_scanner/scanner/method'),
        (call) async {
      if (call.method == 'state') return 1;
      if (call.method == 'start')
        return {
          'textureId': 1,
          'numberOfCameras': 1,
          'size': {'width': 640.0, 'height': 480.0},
        };
      return null;
    });
    f = RegistryFixture();
    await f.seed({
      'devices': [
        {'deviceId': 'source', 'registrationMethod': 'setup'}
      ]
    });
    final source = await f.device('source');
    final invite = await f.invite(source);
    payload = await BlindHandshake(cryptoManager: f.crypto)
        .generateLinkingPayload(
            rootKey: f.root,
            githubToken: 'token-canary',
            repoOwner: 'fixture-owner',
            repoName: 'fixture-repo',
            deviceInviteId: invite);
    storage = await f.device('target', method: 'recovery');
    storage.root = null;
    closed = null;
  });

  Future<void> open(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
        overrides: [
          keyStorageProvider.overrideWithValue(storage),
          cryptoManagerProvider.overrideWithValue(f.crypto),
          gitHubServiceFactoryProvider.overrideWithValue((
                  {required accessToken,
                  required repoOwner,
                  required repoName}) =>
              f.remote),
        ],
        child: MaterialApp(
            home: Scaffold(
                body: Builder(
                    builder: (context) => TextButton(
                        onPressed: () async {
                          closed = await Navigator.of(context).push<bool>(
                              MaterialPageRoute(
                                  builder: (_) => const LinkDeviceScreen(
                                      initialIsSource: false,
                                      allowRoleSwitch: false)));
                        },
                        child: const Text('Open link')))))));
    await tester.tap(find.text('Open link'));
    await settle(tester);
  }

  Future<void> enterCode(WidgetTester tester, {bool scan = false}) async {
    if (scan) {
      final scanner = tester.widget<MobileScanner>(find.byType(MobileScanner));
      scanner.onDetect(
          BarcodeCapture(barcodes: [Barcode(rawValue: payload.qrData)]));
    } else {
      if (!kIsWeb) {
        await tester.tap(find.text('Use Transfer Code Instead'));
        await tester.pumpAndSettle();
      }
      await tester.enterText(find.byType(TextField), payload.qrData);
      await tester.tap(find.text('Continue'));
    }
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), payload.displayPIN);
  }

  Future<void> verify(WidgetTester tester,
      {Future<void> Function()? whileRegistering}) async {
    await tester.runAsync(() async {
      tester
          .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Link Device'))
          .onPressed!();
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    for (var i = 0; i < 50 && find.text('Save').evaluate().isEmpty; i++) {
      await settle(tester);
    }
    expect(find.text('Save'), findsOneWidget);
    await tester.tap(find.text('Save'));
    if (whileRegistering != null) {
      await settle(tester);
      await whileRegistering();
    }
    // Dialog controllers must outlive the route's exit animation.
    for (var i = 0; i < 30 && closed == null; i++) {
      await settle(tester);
    }
    await tester.pumpAndSettle();
    expect(tester.takeException(), null);
  }

  for (final scan in [false, true]) {
    testWidgets(
        'TC-E2E-006 source sync overlaps ${scan ? 'QR' : 'manual'} PIN linking',
        (tester) async {
      final source = await f.device('source');
      final notes =
          NotesRepository(cryptoManager: f.crypto, keyStorage: source);
      final sync = SyncEngine(
          vaultRepository:
              VaultRepository(cryptoManager: f.crypto, keyStorage: source),
          notesRepository: notes,
          githubService: f.remote,
          cryptoManager: f.crypto,
          keyStorage: source);
      await tester.runAsync(() async {
        await sync.initialize();
        await notes.createNote(title: 'During linking', content: 'Source edit');
      });
      late Completer<void> reachedPut;
      late Completer<void> releasePut;
      await tester.runAsync(() async {
        reachedPut = Completer<void>();
        releasePut = Completer<void>();
      });
      addTearDown(() {
        if (!releasePut.isCompleted) releasePut.complete();
      });
      f.remote.beforeRead = () async {
        f.remote.beforeRead = null;
        reachedPut.complete();
        await releasePut.future;
      };
      late Future<SyncResult> syncing;
      await tester.runAsync(() async {
        syncing = sync.sync();
        await reachedPut.future.timeout(const Duration(seconds: 10));
      });
      await open(tester);
      await enterCode(tester, scan: scan);
      await verify(tester, whileRegistering: () async {
        expect(storage.root, orderedEquals(f.root));
        expect(find.text('Save'), findsNothing);
        expect(find.text('Registering this device...'), findsOneWidget);
        expect(closed, null);
        final waiting = (await tester.runAsync(f.decode))!;
        expect(waiting['pendingDeviceInvites'], hasLength(1));
        expect(waiting['devices'],
            isNot(contains(containsPair('deviceId', 'target'))));
        releasePut.complete();
      });
      expect(closed, true);
      expect((await tester.runAsync(() => syncing))!.pushed, 1);
      final registry = (await tester.runAsync(f.decode))!;
      expect(registry['pendingDeviceInvites'], isEmpty);
      expect(
          (registry['devices'] as List).cast<Map>().map((d) => d['deviceId']),
          containsAll(['source', 'target']));
      expect(storage.method, 'link');
      expect(find.byType(RecoveryApprovalDialog), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await Hive.close();
        for (final box in ['notes', 'vault_entries', 'sync_metadata']) {
          await Hive.deleteBoxFromDisk(box);
        }
        final restored =
            NotesRepository(cryptoManager: f.crypto, keyStorage: storage);
        final targetSync = SyncEngine(
            vaultRepository:
                VaultRepository(cryptoManager: f.crypto, keyStorage: storage),
            notesRepository: restored,
            githubService: f.remote,
            cryptoManager: f.crypto,
            keyStorage: storage);
        await targetSync.initialize();
        expect((await targetSync.restoreFromGitHub()).pulled, 1);
        expect(
            (await restored.getAllStoredNotes()).single.content, 'Source edit');
      });
    }, skip: scan && kIsWeb);
  }

  for (final scan in [false, true]) {
    testWidgets(
        'TC-MODAL-015 real ${scan ? 'QR event' : 'manual code'} and PIN '
        'consumes invite without recovery modal', (tester) async {
      await open(tester);
      await enterCode(tester, scan: scan);
      await verify(tester);
      expect(closed, true);
      expect(find.byType(RecoveryApprovalDialog), findsNothing);
      expect(storage.root, orderedEquals(f.root));
      expect(storage.method, 'link');
      expect(storage.invite, null);
      final registry = (await tester.runAsync(f.decode))!;
      expect(registry['pendingDeviceInvites'], isEmpty);
      expect(
          registry['devices'],
          contains(allOf(containsPair('deviceId', 'target'),
              containsPair('registrationMethod', 'link'))));
      await tester.pumpWidget(const SizedBox());
    }, skip: scan && kIsWeb);
  }

  testWidgets(
      'TC-STATE-018/MODAL-016 registration failure after transfer shows warning',
      (tester) async {
    await f.edit((r) => r['pendingDeviceInvites'] = []);
    await open(tester);
    await enterCode(tester);
    await verify(tester);
    expect(closed, true);
    expect(storage.root, orderedEquals(f.root));
    expect(
        find.textContaining(
            'Keys transferred, but device registration is not confirmed'),
        findsOneWidget);
    final registry = (await tester.runAsync(f.decode))!;
    expect(registry['devices'],
        isNot(contains(containsPair('deviceId', 'target'))));
    if (!kIsWeb)
      expect(find.textContaining('Initial sync failed'), findsOneWidget);
    expect(find.byType(RecoveryApprovalDialog), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('wrong PIN cannot persist keys, credentials or trust',
      (tester) async {
    await open(tester);
    await enterCode(tester);
    await tester.enterText(find.byType(TextField),
        payload.displayPIN == '000000' ? '111111' : '000000');
    await tester.runAsync(() async {
      tester
          .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Link Device'))
          .onPressed!();
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    for (var i = 0;
        i < 50 && find.textContaining('Wrong PIN').evaluate().isEmpty;
        i++) {
      await settle(tester);
    }
    expect(find.textContaining('Wrong PIN'), findsWidgets);
    expect(storage.root, null);
    expect(storage.method, 'recovery');
    expect(closed, null);
    expect(f.remote.writes, 1); // Only the source's invite creation.
    await tester.pumpWidget(const SizedBox());
  });
}
