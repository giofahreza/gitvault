import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitvault/core/crypto/key_storage.dart';
import 'package:gitvault/core/providers/providers.dart';
import 'package:gitvault/data/repositories/sync_engine.dart';
import 'package:gitvault/features/settings/settings_screen.dart';
import 'package:hive/hive.dart';

import 'support/registry_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('TC-MIG-006 closed real Hive fails safely and Settings can retry',
      (tester) async {
    late Directory directory;
    late RegistryFixture f;
    late KeyStorage storage;
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('registry-closed-');
      Hive.init(directory.path);
      addTearDown(() => tester.runAsync(() async {
            await Hive.close();
            await directory.delete(recursive: true);
          }));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('com.giofahreza.gitvault/ime'),
              (_) async => null);
      f = RegistryFixture();
      await f.seed({'devices': []});
      storage = KeyStorage();
      await storage.initialize();
      await storage.storeRootKey(f.root);
      await storage.storeDeviceId('local');
      await storage.storeLocalDeviceName('Local');
      await storage.storeGitHubCredentials(
          token: 'test', repoOwner: 'fixture-owner', repoName: 'fixture-repo');
      await Hive.box<String>('secure_keys').close();
      await expectLater(
          SyncEngine.refreshDeviceRegistry(
              keyStorage: storage,
              cryptoManager: f.crypto,
              githubService: f.remote),
          throwsA(isA<HiveError>()));
      expect(f.remote.writes, 0);
    });

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
      child: const MaterialApp(
          home: Scaffold(body: DeviceListSection(isActive: true))),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Devices unavailable. Please retry.'), findsOneWidget);
    expect(find.text('Approve'), findsNothing);
    expect(tester.takeException(), null);
    expect(f.remote.writes, 0);

    // Reopen actual persisted storage; the old KeyStorage must not authorize a
    // write while its box was closed, and a new screen can load the valid state.
    final reopened = KeyStorage();
    await tester.runAsync(reopened.initialize);
    expect(await reopened.getDeviceId(), 'local');
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => SyncEngine.refreshDeviceRegistry(
        keyStorage: reopened,
        cryptoManager: f.crypto,
        githubService: f.remote,
        uploadIfNeeded: false));
    expect(await reopened.getDeviceRegistrySnapshot(), isNotNull);
    expect(f.remote.writes, 0);
  });
}
