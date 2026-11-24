import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitvault/core/crypto/crypto_manager.dart';
import 'package:gitvault/core/crypto/key_storage.dart';
import 'package:gitvault/core/providers/providers.dart';
import 'package:gitvault/core/services/github_service.dart';
import 'package:gitvault/features/settings/settings_screen.dart';
import 'support/memory_registry_storage.dart';

class _ReadService extends GitHubService {
  late Uint8List bytes;
  bool unavailable = false;
  int reads = 0;
  int writes = 0;
  bool allowWrites = false;
  bool failAfterWrite = false;
  Completer<void>? readGate;
  Object? readError;
  _ReadService()
      : super(accessToken: 'test-token', repoOwner: 'owner', repoName: 'repo');
  @override
  Future<RemoteFileSnapshot> readFileSnapshot(String path) async {
    reads++;
    await readGate?.future;
    if (readError != null) throw readError!;
    if (unavailable) throw GitHubException('Unavailable', statusCode: 500);
    return RemoteFileSnapshot(
      bytes: bytes,
      sha: 'sha-$reads',
      serverTime: DateTime.now().toUtc(),
    );
  }

  @override
  Future<String> writeFileSnapshot({
    required String path,
    required Uint8List content,
    required String? expectedSha,
    required String commitMessage,
  }) async {
    if (!allowWrites) throw StateError('UI polling must not write');
    writes++;
    bytes = content;
    if (failAfterWrite) unavailable = true;
    return 'committed-$writes';
  }

  @override
  void dispose() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late KeyStorage storage;
  late CryptoManager crypto;
  late Uint8List root;
  late _ReadService github;

  Future<void> remote(Map<String, dynamic> registry) async {
    final box = await crypto.encryptXChaCha20(
      data: crypto.addRandomPadding(
        Uint8List.fromList(utf8.encode(jsonEncode(registry))),
      ),
      key: root,
    );
    github.bytes = box.toBytes();
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 120)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester, {bool active = true}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          keyStorageProvider.overrideWithValue(storage),
          cryptoManagerProvider.overrideWithValue(crypto),
          gitHubServiceFactoryProvider.overrideWithValue(
            ({
              required accessToken,
              required repoOwner,
              required repoName,
            }) =>
                github,
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: DeviceListSection(isActive: active),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  setUpAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.giofahreza.gitvault/ime'),
      (_) async => null,
    );
  });
  setUp(() async {
    storage = MemoryRegistryStorage();
    crypto = CryptoManager();
    root = crypto.generateRandomKey();
    github = _ReadService();
    await storage.initialize();
    await storage.storeRootKey(root);
    await storage.storeDeviceId('local');
    await storage.storeLocalDeviceName('Local Laptop');
    await storage.storeGitHubCredentials(
      token: 'test-token',
      repoOwner: 'owner',
      repoName: 'repo',
    );
    await remote({
      'devices': [
        {
          'deviceId': 'local',
          'name': 'Local Laptop',
          'registrationMethod': 'setup',
        }
      ],
      'pendingDeviceApprovals': [
        {
          'approvalId': 'r1',
          'deviceId': 'requester',
          'deviceName': 'New Phone',
          'status': 'pending',
          'expiresAt':
              DateTime.now().add(const Duration(minutes: 1)).toIso8601String(),
        }
      ],
    });
  });

  testWidgets(
      'read failure hides cached approval actions and shows stale state',
      (tester) async {
    await open(tester);
    expect(find.text('Approve'), findsOneWidget);
    github.unavailable = true;
    await tester.pump(const Duration(seconds: 3));
    await settle(tester);
    expect(find.text('Approve'), findsNothing);
    expect(find.text('Deny'), findsNothing);
    expect(find.text('Device list is not confirmed'), findsOneWidget);
    expect(find.text('Local Laptop'), findsOneWidget);
    github.unavailable = false;
    await tester.tap(find.byTooltip('Retry device refresh'));
    await settle(tester);
    expect(find.text('Approve'), findsOneWidget);
    expect(find.text('Device list is not confirmed'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('valid empty remote stays authoritative', (tester) async {
    await open(tester);
    expect(find.text('Approve'), findsOneWidget);
    await tester.runAsync(() => remote({'devices': []}));
    await tester.pump(const Duration(seconds: 3));
    await settle(tester);
    expect(find.text('Approve'), findsNothing);
    expect(find.text('Device list is not confirmed'), findsNothing);
    final cached = jsonDecode((await storage.getDeviceRegistrySnapshot())!);
    expect(cached['registry']['devices'], isEmpty);
    expect(cached['stale'], false);
    await tester.pumpWidget(const SizedBox());
  });

  for (final status in ['approved', 'completed']) {
    testWidgets('TC-CACHE-006 real $status transition removes pending actions',
        (tester) async {
      await open(tester);
      final cached = jsonDecode((await storage.getDeviceRegistrySnapshot())!);
      final registry = Map<String, dynamic>.from(cached['registry'] as Map);
      final request =
          (registry['pendingDeviceApprovals'] as List).single as Map;
      request['status'] = 'approved';
      request['respondedAt'] = DateTime.now().toUtc().toIso8601String();
      request['respondedByDeviceId'] = 'local';
      if (status == 'completed') {
        request['completedAt'] = DateTime.now().toUtc().toIso8601String();
      }
      await tester.runAsync(() => remote(registry));
      await tester.pump(const Duration(seconds: 3));
      await settle(tester);
      expect(find.text('Approve'), findsNothing);
      expect(find.text('Deny'), findsNothing);
      final updated = jsonDecode((await storage.getDeviceRegistrySnapshot())!);
      expect(updated['registry'], registry);
      expect(updated['stale'], false);
      expect(github.writes, 0);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('TC-CACHE-007 slow Settings reads never overlap timer loads',
      (tester) async {
    await open(tester);
    final before = github.reads;
    github.readGate = Completer<void>();
    await tester.pump(const Duration(seconds: 3));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    expect(github.reads, before + 1);
    await tester.pump(const Duration(seconds: 12));
    expect(github.reads, before + 1);
    github.readGate!.complete();
    github.readGate = null;
    await settle(tester);
    expect(find.text('Approve'), findsOneWidget);
    expect(github.writes, 0);
    await tester.pumpWidget(const SizedBox());
  });

  for (final fails in [false, true]) {
    testWidgets('TC-CACHE-008 Settings inactive during read fails=$fails',
        (tester) async {
      await open(tester);
      github.readGate = Completer<void>();
      await tester.pump(const Duration(seconds: 3));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      final reads = github.reads;
      await open(tester, active: false);
      github.unavailable = fails;
      github.readGate!.complete();
      github.readGate = null;
      await settle(tester);
      await tester.pump(const Duration(seconds: 12));
      expect(github.reads, reads);
      expect(github.writes, 0);
      expect(tester.takeException(), null);
      expect(find.text('Approve'), fails ? findsNothing : findsOneWidget);
      github.unavailable = false;
      await open(tester, active: true);
      expect(github.reads, reads + 1);
      expect(find.text('Approve'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('TC-CACHE-008 Settings disposed during read fails=$fails',
        (tester) async {
      await open(tester);
      github.readGate = Completer<void>();
      await tester.pump(const Duration(seconds: 3));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      final reads = github.reads;
      await tester.pumpWidget(const SizedBox());
      github.unavailable = fails;
      github.readGate!.complete();
      github.readGate = null;
      await settle(tester);
      await tester.pump(const Duration(seconds: 9));
      expect(tester.takeException(), null);
      expect(github.reads, reads);
      expect(github.writes, 0);
    });
  }

  testWidgets(
      'TC-CACHE-009 stale state survives inactive and failed reactivation',
      (tester) async {
    await open(tester);
    github.unavailable = true;
    await tester.pump(const Duration(seconds: 3));
    await settle(tester);
    await open(tester, active: false);
    await open(tester, active: true);
    expect(find.text('Approve'), findsNothing);
    expect(find.text('Device list is not confirmed'), findsOneWidget);
    github.unavailable = false;
    await tester.pump(const Duration(seconds: 3));
    await settle(tester);
    expect(find.text('Approve'), findsOneWidget);
    expect(find.text('Device list is not confirmed'), findsNothing);
    expect(github.writes, 0);
    await tester.pumpWidget(const SizedBox());
  });

  for (final failure in [
    'timeout',
    'network',
    'tampered',
    '401',
    '403',
    '404',
    '429',
    '500',
    'invalid_data'
  ]) {
    testWidgets(
        'TC-READ-010/012/CACHE-005 $failure preserves stale Settings data',
        (tester) async {
      await open(tester);
      final events = <Map<String, dynamic>>[];
      final originalPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null && message.startsWith('{')) {
          events.add(jsonDecode(message) as Map<String, dynamic>);
        }
      };
      try {
        final cached = jsonDecode((await storage.getDeviceRegistrySnapshot())!);
        final httpStatus = int.tryParse(failure);
        final kind = failure == '404'
            ? 'missing_branch'
            : failure == '429'
                ? 'rate_limit'
                : httpStatus != null
                    ? 'http'
                    : failure == 'tampered'
                        ? 'invalid_data'
                        : failure;
        if (failure == 'tampered') {
          github.bytes = Uint8List.fromList(github.bytes);
          github.bytes[github.bytes.length - 1] ^= 1;
        } else {
          github.readError = GitHubException('Unavailable',
              kind: kind, statusCode: httpStatus);
        }
        await tester.pump(const Duration(seconds: 3));
        await settle(tester);
        expect(find.text('Approve'), findsNothing);
        expect(find.text('Device list is not confirmed'), findsOneWidget);
        expect(find.text('Local Laptop'), findsOneWidget);
        final stale = jsonDecode((await storage.getDeviceRegistrySnapshot())!);
        expect(stale['registry'], cached['registry']);
        expect(stale['stale'], true);
        expect(stale['sha'], cached['sha']);
        final diagnostic = events.lastWhere((e) => e['state'] == 'failed');
        expect(diagnostic['errorKind'], kind);
        expect(diagnostic['httpStatus'], httpStatus);
        expect(events.toString(), isNot(contains('test-token')));
        expect(github.writes, 0);
        await tester.pumpWidget(const SizedBox());
      } finally {
        debugPrint = originalPrint;
      }
    });
  }

  for (final method in ['sync', 'recovery', 'future-trust-method']) {
    testWidgets('TC-MIG-002/STATE-022 $method is shown for review',
        (tester) async {
      await remote({
        'devices': [
          {'deviceId': 'local', 'registrationMethod': 'setup'},
          {
            'deviceId': 'other',
            'name': 'Other Device',
            'registrationMethod': method
          },
        ]
      });
      await open(tester);
      expect(find.text('I recognize this device'), findsOneWidget);
      expect(find.text('Other Device'), findsOneWidget);
      expect(github.writes, 0);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('TC-CACHE-010 dismissal is cleared by confirmed trust change',
      (tester) async {
    Map<String, dynamic> registry(String method) => {
          'devices': [
            {'deviceId': 'local', 'registrationMethod': 'setup'},
            {
              'deviceId': 'other',
              'name': 'Other Device',
              'registrationMethod': method
            },
          ]
        };
    await remote(registry('sync'));
    await open(tester);
    await tester.ensureVisible(find.text('Dismiss').first);
    await tester.tap(find.text('Dismiss').first);
    await settle(tester);
    expect(find.text('I recognize this device'), findsNothing);
    expect(await storage.getDismissedUnverifiedDeviceIds(), contains('other'));
    await tester.runAsync(() => remote(registry('recognized')));
    await tester.pump(const Duration(seconds: 3));
    await settle(tester);
    expect(jsonDecode((await storage.getDismissedUnverifiedDeviceIds())!),
        isEmpty);
    await tester.runAsync(() => remote(registry('sync')));
    await tester.pump(const Duration(seconds: 3));
    await settle(tester);
    expect(find.text('I recognize this device'), findsOneWidget);
    expect(github.writes, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'TC-CACHE-011 successful recognition with failed follow-up stays stale',
      (tester) async {
    await remote({
      'devices': [
        {'deviceId': 'local', 'registrationMethod': 'setup'},
        {
          'deviceId': 'other',
          'name': 'Other Device',
          'registrationMethod': 'sync'
        },
      ]
    });
    github.allowWrites = true;
    github.failAfterWrite = true;
    await open(tester);
    await tester.ensureVisible(find.text('I recognize this device'));
    await tester.tap(find.text('I recognize this device'));
    await settle(tester);
    expect(github.writes, 1);
    expect(find.text('Device list is not confirmed'), findsOneWidget);
    final snapshot = jsonDecode((await storage.getDeviceRegistrySnapshot())!);
    expect(snapshot['stale'], true);
    expect(
        snapshot['registry']['devices'],
        contains(allOf(containsPair('deviceId', 'other'),
            containsPair('registrationMethod', 'recognized'))));
    await tester.pump(const Duration(seconds: 6));
    await settle(tester);
    expect(github.writes, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('TC-MIG-005 malformed cache recovers from valid remote state',
      (tester) async {
    await storage.storeDeviceRegistrySnapshot('{bad-json');
    await storage.storeDeviceRegistry('{also-bad-json');
    await open(tester);
    expect(find.text('Approve'), findsOneWidget);
    final snapshot = jsonDecode((await storage.getDeviceRegistrySnapshot())!);
    expect(snapshot['stale'], false);
    expect(snapshot['sha'], 'sha-1');
    expect(snapshot['scope'], 'owner/repo@data');
    expect(github.writes, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'inactive settings stops polling and returning triggers fresh read',
      (tester) async {
    await open(tester);
    await open(tester, active: false);
    final reads = github.reads;
    await tester.pump(const Duration(seconds: 12));
    expect(github.reads, reads);
    await open(tester, active: true);
    expect(github.reads, greaterThan(reads));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'wrong repository cache is not displayed when remote is unavailable',
      (tester) async {
    await storage.storeDeviceRegistrySnapshot(
      jsonEncode({
        'scope': 'other/repo@data',
        'registry': {
          'devices': [
            {'deviceId': 'other', 'name': 'Other Vault Device'},
          ],
          'pendingDeviceApprovals': [
            {'approvalId': 'secret', 'status': 'pending'},
          ],
        },
      }),
    );
    github.unavailable = true;
    await open(tester);
    expect(find.text('Other Vault Device'), findsNothing);
    expect(find.text('Approve'), findsNothing);
    expect(find.text('Device list is not confirmed'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
