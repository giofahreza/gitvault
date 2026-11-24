import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitvault/core/services/github_service.dart';
import 'package:gitvault/data/repositories/sync_engine.dart';

import 'support/memory_registry_storage.dart';
import 'support/registry_fixture.dart';
import 'support/browser_clock_stub.dart'
    if (dart.library.html) 'support/browser_clock_web.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.utc(2030, 1, 1);
  late RegistryFixture f;
  late MemoryRegistryStorage approver, requester;

  Map<String, dynamic> approval({String id = 'r1', String device = 'new'}) => {
        'approvalId': id,
        'deviceId': device,
        'deviceName': 'Name $device',
        'status': 'pending',
        'requestedAt': now.toIso8601String(),
        'expiresAt': now.add(const Duration(seconds: 30)).toIso8601String(),
      };

  Map<String, dynamic> answered({String id = 'r1', String device = 'new'}) => {
        ...approval(id: id, device: device),
        'status': 'approved',
        'respondedAt': now.toIso8601String(),
        'respondedByDeviceId': 'trusted',
        'respondedByName': 'Name trusted',
      };

  Future<Map> requestRecord([String id = 'r1']) async =>
      ((await f.decode())['pendingDeviceApprovals'] as List)
          .cast<Map>()
          .singleWhere((r) => r['approvalId'] == id);

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.giofahreza.gitvault/ime'),
      (_) async => null,
    );
    f = RegistryFixture();
    f.remote.serverTime = now;
    await f.seed({
      'devices': [
        {
          'deviceId': 'trusted',
          'name': 'Name trusted',
          'registrationMethod': 'setup',
        },
      ],
      'pendingDeviceApprovals': [approval()],
      'futureField': {
        'opaque': ['preserve', 7]
      },
    });
    approver = await f.device('trusted');
    requester = await f.device('new', method: 'recovery');
  });

  test('TC-STATE-001/005 approval metadata is durable and irreversible',
      () async {
    await f.respond(approver, 'r1');
    final record = await requestRecord();
    expect(record['respondedByDeviceId'], 'trusted');
    expect(record['respondedByName'], 'Name trusted');
    expect(
        DateTime.parse(record['respondedAt'] as String).isBefore(now), false);
    final writes = f.remote.writes;
    await f.respond(approver, 'r1');
    await expectLater(
        f.respond(approver, 'r1', approved: false), throwsStateError);
    expect(await requestRecord(), record);
    expect(f.remote.writes, writes);
  });

  test('TC-STATE-002 denial commits metadata and cannot be reversed', () async {
    await f.respond(approver, 'r1', approved: false);
    final record = await requestRecord();
    expect(record['status'], 'denied');
    expect(record['respondedByDeviceId'], 'trusted');
    expect(record['respondedByName'], 'Name trusted');
    expect(DateTime.tryParse(record['respondedAt'] as String), isNotNull);
    expect((await f.status(requester, 'r1')).isDenied, true);
    await expectLater(f.respond(approver, 'r1'), throwsStateError);
    await expectLater(f.complete(requester, 'r1'), throwsStateError);
    expect(await requestRecord(), record);
    expect(f.remote.writes, 1);
  });

  test('TC-STATE-004 timely response completes after expiry exactly once',
      () async {
    await f.respond(approver, 'r1');
    final response = await requestRecord();
    f.remote.serverTime = now.add(const Duration(days: 2));
    expect((await f.status(requester, 'r1')).isApproved, true);
    await f.complete(requester, 'r1');
    final completed = await f.decode();
    final registered = (completed['devices'] as List).cast<Map>().last;
    expect(registered['deviceId'], 'new');
    expect(registered['approvedAt'], response['respondedAt']);
    expect(registered['approvedByDeviceId'], 'trusted');
    expect(registered['recoveryApprovalId'], 'r1');
    expect((await requestRecord())['completedAt'], isNotNull);
    final writes = f.remote.writes;
    await f.complete(requester, 'r1');
    expect(await f.decode(), completed);
    expect(f.remote.writes, writes);
  });

  test('TC-STATE-010 completion cannot resurrect a deleted request on conflict',
      () async {
    await f.edit((r) => r['pendingDeviceApprovals'] = [answered()]);
    f.remote.beforeWrite =
        () => f.edit((r) => r['pendingDeviceApprovals'] = []);
    await expectLater(f.complete(requester, 'r1'), throwsStateError);
    final registry = await f.decode();
    expect(registry['pendingDeviceApprovals'], isEmpty);
    expect(
        (registry['devices'] as List)
            .cast<Map>()
            .where((d) => d['deviceId'] == 'new'),
        isEmpty);
    expect(f.remote.conflicts, 1);
    expect(f.remote.writes, 0);
  });

  for (final method in [
    'setup',
    'link',
    'recognized',
    'recovery_approved',
    'recovery_token_rotated'
  ]) {
    test('TC-CON-013/STATE-011 recognize $method is an exact no-op', () async {
      final original = {
        'deviceId': 'other',
        'registrationMethod': method,
        'linkedAt': 'opaque timestamp',
        'linkedInviteId': 'historical-invite',
        'recognizedAt': 'original recognition',
        'futureMetadata': {'x': 1},
      };
      await f.edit((r) => (r['devices'] as List).add(original));
      await f.recognize(approver, 'other');
      expect(((await f.decode())['devices'] as List).last, original);
      expect(f.remote.attempts, isEmpty);
    });
  }

  for (final deleted in [false, true]) {
    test(
        'TC-CON-014 recognition handles ${deleted ? 'deletion' : 'revocation'} '
        'during retry', () async {
      await f.edit((r) => (r['devices'] as List).add({
            'deviceId': 'target',
            'registrationMethod': 'sync',
          }));
      f.remote.beforeWrite = () => f.edit((r) {
            (r['devices'] as List)
                .removeWhere((d) => d['deviceId'] == 'target');
            if (!deleted)
              r['revokedDevices'] = [
                {'deviceId': 'target'}
              ];
          });
      if (deleted) {
        await f.recognize(approver, 'target');
      } else {
        await expectLater(f.recognize(approver, 'target'),
            throwsA(isA<DeviceRevokedException>()));
      }
      expect((await f.decode())['devices'],
          isNot(contains(containsPair('deviceId', 'target'))));
      expect(f.remote.writes, 0);
    });
  }

  test('TC-CON-014 completion rejects revocation during retry', () async {
    await f.edit((r) => r['pendingDeviceApprovals'] = [answered()]);
    f.remote.beforeWrite = () => f.edit((r) {
          r['revokedDevices'] = [
            {'deviceId': 'new'}
          ];
        });
    await expectLater(
        f.complete(requester, 'r1'), throwsA(isA<DeviceRevokedException>()));
    expect((await requestRecord())['completedAt'], isNull);
    expect(f.remote.writes, 0);
  });

  test('TC-CON-001 valid approval survives conflicting heartbeat and completes',
      () async {
    f.remote.beforeWrite = () => f.edit((r) {
          r['pendingDeviceApprovals'] = [answered()];
        });
    await f.refresh(approver);
    expect(f.remote.conflicts, 1);
    expect((await f.status(requester, 'r1')).isApproved, true);
    await f.complete(requester, 'r1');
    expect((await requestRecord())['completedAt'], isNotNull);
    expect((await f.decode())['futureField'], f.initial['futureField']);
  });

  test('TC-CON-003 competing valid approvals both remain usable', () async {
    await f.edit((r) => (r['pendingDeviceApprovals'] as List)
        .add(approval(id: 'r2', device: 'second')));
    f.remote.beforeWrite = () => f.edit((r) {
          (r['pendingDeviceApprovals'] as List)[1] =
              answered(id: 'r2', device: 'second');
        });
    await f.respond(approver, 'r1');
    final second = await f.device('second', method: 'recovery');
    for (final pair in [(requester, 'r1'), (second, 'r2')]) {
      expect((await f.status(pair.$1, pair.$2)).isApproved, true);
      await f.complete(pair.$1, pair.$2);
    }
    expect((await f.decode())['pendingDeviceApprovals'],
        everyElement(containsPair('completedAt', isNotNull)));
  });

  for (final recognitionFirst in [true, false]) {
    test(
        'TC-CON-002/STATE-012 recognition and stale refresh both survive '
        'order=$recognitionFirst', () async {
      final target = await f.device('target', method: 'sync');
      await f.edit((r) => (r['devices'] as List).add({
            'deviceId': 'target',
            'registrationMethod': 'sync',
          }));
      if (recognitionFirst) {
        f.remote.beforeWrite = () => f.edit((r) {
              (r['devices'] as List).last.addAll({
                'registrationMethod': 'recognized',
                'recognizedAt': now.toIso8601String(),
                'recognizedByDeviceId': 'trusted',
              });
            });
        await f.refresh(target);
      } else {
        f.remote.beforeWrite = () => f.edit((r) {
              (r['devices'] as List).last['lastSeen'] = now.toIso8601String();
            });
        await f.recognize(approver, 'target');
        await f.refresh(target);
      }
      final device = ((await f.decode())['devices'] as List).last as Map;
      expect(device['registrationMethod'], 'recognized');
      expect(device['recognizedAt'], isNotNull);
      expect(device['lastSeen'], isNotNull);
      expect(f.remote.conflicts, 1);
    });
  }

  test('TC-CON-007 new invite survives competing consumption of another',
      () async {
    await f.edit((r) => r['pendingDeviceInvites'] = [
          {
            'inviteId': 'old',
            'createdByDeviceId': 'trusted',
            'expiresAt': now.add(const Duration(minutes: 5)).toIso8601String(),
          }
        ]);
    f.remote.beforeWrite = () => f.edit((r) {
          r['pendingDeviceInvites'] = [];
          (r['devices'] as List).add({
            'deviceId': 'linked',
            'registrationMethod': 'link',
            'linkedInviteId': 'old',
          });
        });
    final id = await f.invite(approver);
    final registry = await f.decode();
    expect(registry['pendingDeviceInvites'], [containsPair('inviteId', id)]);
    expect(registry['devices'], contains(containsPair('deviceId', 'linked')));
    expect(registry['futureField'], f.initial['futureField']);
  });

  test('TC-CON-012 retry uses new SHA, nonce and rebased plaintext', () async {
    final firstSha = f.remote.sha;
    String? competingSha;
    f.remote.beforeWrite = () async {
      await f.edit((r) => r['competing'] = {'must': 'survive'});
      competingSha = f.remote.sha;
    };
    await f.respond(approver, 'r1');
    expect(f.remote.attempts, hasLength(2));
    final first = f.remote.attempts.first;
    final second = f.remote.attempts.last;
    expect(first.expectedSha, firstSha);
    expect(second.expectedSha, competingSha);
    expect(
        first.content.take(24), isNot(orderedEquals(second.content.take(24))));
    expect((await f.decode(first.content)).containsKey('competing'), false);
    expect((await f.decode(second.content))['competing'], {'must': 'survive'});
    expect((await f.decode(second.content))['pendingDeviceApprovals'],
        [containsPair('status', 'approved')]);
  });

  for (final operation in [
    'completion',
    'invite consumption',
    'recognition',
    'revocation',
    'token rotation'
  ]) {
    test('TC-CON-015 ambiguous $operation commits once and can be retried',
        () async {
      late Future<void> Function() action;
      switch (operation) {
        case 'completion':
          await f.edit((r) => r['pendingDeviceApprovals'] = [answered()]);
          action = () => f.complete(requester, 'r1');
        case 'invite consumption':
          requester.method = 'link';
          requester.invite = 'i1';
          await f.edit((r) => r['pendingDeviceInvites'] = [
                {
                  'inviteId': 'i1',
                  'createdByDeviceId': 'trusted',
                  'expiresAt':
                      now.add(const Duration(minutes: 1)).toIso8601String(),
                }
              ]);
          action = () async {
            await f.refresh(requester);
          };
        case 'recognition':
          await f.edit((r) => (r['devices'] as List).add({
                'deviceId': 'new',
                'registrationMethod': 'sync',
              }));
          action = () => f.recognize(approver, 'new');
        case 'revocation':
          await f.edit((r) => (r['devices'] as List).add({
                'deviceId': 'new',
                'registrationMethod': 'link',
              }));
          action = () => f.revoke(approver, 'new');
        case 'token rotation':
          action = () => SyncEngine.completeTokenRotatedRecovery(
                keyStorage: requester,
                cryptoManager: f.crypto,
                githubService: f.remote,
                rootKey: f.root,
                oldToken: 'old',
                newToken: 'new-token',
                approvalId: 'r1',
              );
      }
      f.remote.loseNextResponse = true;
      await action();
      final committed = await f.decode();
      expect(f.remote.writes, 1);
      await action();
      expect(f.remote.writes, 1);
      expect(await f.decode(), committed);
      expect(committed['futureField'], f.initial['futureField']);
      final cached = jsonDecode(requester.snapshot ?? approver.snapshot!);
      expect(cached['stale'], false);
      expect(cached['sha'], f.remote.sha);
    });
  }

  for (final skew in [-365, 365]) {
    test('TC-STATE-013 server-time flow works with ${skew}d clock offset',
        () async {
      f.remote.serverTime = DateTime.now().toUtc().add(Duration(days: skew));
      final id = await f.request(requester);
      expect((await f.status(requester, id)).isPending, true);
      await f.respond(approver, id);
      f.remote.serverTime =
          f.remote.serverTime!.add(const Duration(minutes: 5));
      expect((await f.status(requester, id)).isApproved, true);
      await f.complete(requester, id);
      expect((await requestRecord(id))['completedAt'], isNotNull);
    });
  }

  if (kIsWeb) {
    for (final days in [-365, 365]) {
      for (final hiddenDate in [false, true]) {
        test(
            'TC-STATE-013 browser Date offset ${days}d, hidden Date=$hiddenDate',
            () async {
          addTearDown(() => setBrowserClockOffset(Duration.zero));
          final realNow = DateTime.now().toUtc();
          f.remote.serverTime = realNow;
          f.remote.hideServerTime = hiddenDate;
          requester.root = null;
          final id = await f.request(requester);
          final before = f.remote.writes;
          setBrowserClockOffset(Duration(days: days));
          expect(DateTime.now().toUtc().difference(realNow).inMilliseconds,
              closeTo(Duration(days: days).inMilliseconds, 5000),
              reason: 'The browser clock itself must change');
          if (hiddenDate) {
            await expectLater(f.respond(approver, id), throwsStateError);
            setBrowserClockOffset(Duration.zero);
            final status = await f.status(requester, id);
            expect(days > 0 ? status.isExpired : status.isPending, true);
            expect(f.remote.writes, before + (days > 0 ? 1 : 0));
            expect((await f.decode())['devices'],
                isNot(contains(containsPair('deviceId', 'new'))));
            expect(requester.method, 'recovery');
          } else {
            await f.respond(approver, id);
            // Change device again; a requester with a different local clock
            // still observes and completes the durable timely response.
            setBrowserClockOffset(Duration(days: -days));
            expect((await f.status(requester, id)).isApproved, true);
            await f.complete(requester, id);
            expect((await requestRecord(id))['completedAt'], isNotNull);
            expect((await f.decode())['devices'],
                contains(containsPair('deviceId', 'new')));
            final committedWrites = f.remote.writes;
            await f.complete(requester, id);
            expect(f.remote.writes, committedWrites);
          }
          expect(requester.root, null,
              reason: 'Registry confirmation alone must not persist root keys');
        });
      }
    }
  }

  for (final offset in [-1, 0]) {
    test('TC-STATE-016 existing invite expired at offset $offset cannot link',
        () async {
      requester.method = 'link';
      requester.invite = 'expired';
      await f.edit((r) => r['pendingDeviceInvites'] = [
            {
              'inviteId': 'expired',
              'createdByDeviceId': 'trusted',
              'expiresAt': now.add(Duration(seconds: offset)).toIso8601String(),
            }
          ]);
      final original = await f.decode();
      await expectLater(f.refresh(requester), throwsStateError);
      expect(await f.decode(), original);
      expect(f.remote.writes, 0);
      expect(requester.invite, 'expired');
    });
  }

  test('TC-STATE-017 same-device consumed invite replay cannot duplicate trust',
      () async {
    requester.method = 'link';
    requester.invite = await f.invite(approver);
    final id = requester.invite!;
    await f.refresh(requester);
    requester.invite = id;
    final writes = f.remote.writes;
    await f.refresh(requester);
    expect(f.remote.writes, writes);
    expect(
        ((await f.decode())['devices'] as List)
            .cast<Map>()
            .where((d) => d['deviceId'] == 'new'),
        hasLength(1));
    final other = await f.device('other', method: 'link');
    other.invite = id;
    await expectLater(f.refresh(other), throwsStateError);
    expect(f.remote.writes, writes);
  });

  test('TC-STATE-019 stale work cannot restore a revoked requester or inviter',
      () async {
    await f.edit((r) {
      (r['devices'] as List)
          .add({'deviceId': 'new', 'registrationMethod': 'link'});
      r['pendingDeviceApprovals'] = [answered()];
      r['pendingDeviceInvites'] = [
        {
          'inviteId': 'stale',
          'createdByDeviceId': 'new',
          'expiresAt': now.add(const Duration(minutes: 1)).toIso8601String(),
        }
      ];
    });
    final stale = await f.decode();
    await f.revoke(approver, 'new');
    await f.edit((r) {
      // An old client reinserts the records but preserves the tombstone.
      r['pendingDeviceApprovals'] = stale['pendingDeviceApprovals'];
      r['pendingDeviceInvites'] = stale['pendingDeviceInvites'];
    });
    await expectLater(
        f.complete(requester, 'r1'), throwsA(isA<DeviceRevokedException>()));
    final link = await f.device('other', method: 'link');
    link.invite = 'stale';
    await expectLater(f.refresh(link), throwsStateError);
    expect(f.remote.writes, 1);
  });

  test('TC-STATE-021 valid invite removes tombstone only when relink commits',
      () async {
    requester.method = 'link';
    requester.invite = 'fresh';
    await f.edit((r) {
      r['revokedDevices'] = [
        {'deviceId': 'new'}
      ];
      r['pendingDeviceInvites'] = [
        {
          'inviteId': 'fresh',
          'createdByDeviceId': 'trusted',
          'expiresAt': now.add(const Duration(minutes: 1)).toIso8601String(),
        }
      ];
    });
    f.remote.writeError = GitHubException('Forbidden', statusCode: 403);
    await expectLater(f.refresh(requester), throwsA(isA<GitHubException>()));
    expect((await f.decode())['revokedDevices'],
        [containsPair('deviceId', 'new')]);
    expect(requester.invite, 'fresh');
    f.remote.writeError = null;
    await f.refresh(requester);
    expect((await f.decode())['revokedDevices'], isEmpty);
    expect(
        (await f.decode())['devices'],
        contains(allOf(containsPair('deviceId', 'new'),
            containsPair('registrationMethod', 'link'))));
  });

  test('TC-MIG-003 approved legacy request without respondedAt never completes',
      () async {
    await f.edit((r) {
      r['pendingDeviceApprovals'] = [
        {...approval(), 'status': 'approved'}
      ];
    });
    expect((await f.status(requester, 'r1')).isExpired, true);
    await expectLater(f.complete(requester, 'r1'), throwsStateError);
    expect(f.remote.writes, 0);
  });

  test('TC-MIG-004 future status and nested fields survive unrelated mutation',
      () async {
    await f.edit((r) {
      (r['pendingDeviceApprovals'] as List).single.addAll({
        'status': 'future-status',
        'futureNested': {
          'secret': ['opaque']
        },
      });
    });
    final original = await requestRecord();
    await f.refresh(approver);
    expect(await requestRecord(), original);
    expect((await f.decode())['futureField'], f.initial['futureField']);
  });

  test('TC-SEC-008 whitespace IDs are distinct during recognition and revoke',
      () async {
    final devices = [
      for (final id in ['phone', ' phone', 'phone ', 'Phone'])
        {'deviceId': id, 'name': 'Same', 'registrationMethod': 'sync'},
    ];
    await f.edit((r) => (r['devices'] as List).addAll(devices));
    await f.recognize(approver, ' phone');
    await f.revoke(approver, 'phone ');
    final registry = await f.decode();
    expect(
        (registry['devices'] as List).cast<Map>().singleWhere(
            (d) => d['deviceId'] == ' phone')['registrationMethod'],
        'recognized');
    for (final id in ['phone', 'Phone']) {
      expect(
          (registry['devices'] as List)
              .cast<Map>()
              .singleWhere((d) => d['deviceId'] == id),
          devices.singleWhere((d) => d['deviceId'] == id));
    }
    expect(registry['revokedDevices'], [containsPair('deviceId', 'phone ')]);
  });

  test('TC-SEC-008 registration keeps case and whitespace identities distinct',
      () async {
    final original = (await f.decode())['devices'];
    for (final id in ['phone', ' phone', 'phone ', 'Phone']) {
      await f.refresh(await f.device(id));
    }
    final devices = ((await f.decode())['devices'] as List).cast<Map>();
    expect(devices.map((d) => d['deviceId']).toSet(),
        {'trusted', 'phone', ' phone', 'phone ', 'Phone'});
    expect(devices.singleWhere((d) => d['deviceId'] == 'trusted'),
        (original as List).single);
    for (final id in ['phone', ' phone', 'phone ', 'Phone']) {
      expect(devices.singleWhere((d) => d['deviceId'] == id)['name'],
          ('Name $id').trim());
    }
  });

  for (final failure in [
    'timeout',
    'network',
    'empty',
    'malformed',
    'tampered',
    'wrong-key'
  ]) {
    test(
        'TC-READ-010/011/012/CACHE-005/SEC-004 $failure preserves cache and '
        'never uploads', () async {
      await f.refresh(approver, upload: false);
      final original = jsonDecode(approver.snapshot!) as Map;
      final legacy = approver.registry;
      if (failure == 'timeout' || failure == 'network') {
        f.remote.readError = GitHubException('Unavailable', kind: failure);
      } else if (failure == 'empty') {
        f.remote.bytes = Uint8List(0);
      } else if (failure == 'malformed') {
        f.remote.bytes = Uint8List.fromList([1, 2, 3]);
      } else if (failure == 'tampered') {
        f.remote.bytes = Uint8List.fromList(f.remote.bytes!);
        f.remote.bytes![f.remote.bytes!.length - 1] ^= 1;
      } else {
        approver.root = f.crypto.generateRandomKey();
      }
      for (final upload in [false, true]) {
        await expectLater(f.refresh(approver, upload: upload),
            throwsA(isA<GitHubException>()));
        final cached = jsonDecode(approver.snapshot!) as Map;
        expect(cached['stale'], true);
        expect(cached['registry'], original['registry']);
        expect(cached['sha'], original['sha']);
        expect(approver.registry, legacy);
      }
      expect(f.remote.attempts, isEmpty);
    });
  }

  test('TC-CACHE-001/MIG-001 legacy cache gains confirmed observation metadata',
      () async {
    approver.registry = jsonEncode({
      'devices': [
        {'deviceId': 'legacy'}
      ]
    });
    expect(approver.snapshot, isNull);
    final sha = f.remote.sha;
    await f.refresh(approver, upload: false);
    final cache = jsonDecode(approver.snapshot!);
    expect(cache['sha'], sha);
    expect(cache['scope'], f.remote.registryScope);
    expect(cache['clockSource'], 'github');
    expect(cache['stale'], false);
    final observed = DateTime.parse(cache['observedAt'] as String);
    expect(observed.difference(now).inSeconds, 0);
    expect(cache['registry'], await f.decode());
    expect(f.remote.attempts, isEmpty);
  });

  test('TC-OBS-006 uncommitted optimistic cache cannot authorize completion',
      () async {
    approver.registry = jsonEncode({'devices': []});
    requester.snapshot = jsonEncode({
      'scope': f.remote.registryScope,
      'stale': false,
      'sha': 'uncommitted',
      'registry': {
        'devices': [],
        'pendingDeviceApprovals': [answered()]
      },
    });
    expect((await f.status(requester, 'r1')).isPending, true);
    await expectLater(f.complete(requester, 'r1'), throwsStateError);
    f.remote.readError = GitHubException('Offline', kind: 'network');
    await expectLater(
        f.complete(requester, 'r1'), throwsA(isA<GitHubException>()));
    expect(f.remote.writes, 0);
  });

  for (final scenario in [
    'approve',
    'complete',
    'conflict',
    'exhausted',
    'read'
  ]) {
    test(
        'TC-SEC-005/OBS-001/002/003/004 $scenario diagnostics are redacted '
        'and report final outcome', () async {
      await f.edit((r) => r['canary'] = 'mnemonic-vault-body-canary');
      if (scenario == 'complete') {
        await f.edit((r) => r['pendingDeviceApprovals'] = [answered()]);
      }
      if (scenario == 'conflict') f.remote.forcedConflicts = 2;
      if (scenario == 'exhausted') f.remote.forcedConflicts = 4;
      if (scenario == 'read') {
        f.remote.readError =
            GitHubException('token-canary', statusCode: 403, kind: 'http');
      }
      final captured = <String>[];
      final original = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) captured.add(message);
      };
      final readSha = f.remote.sha;
      try {
        final action = scenario == 'complete'
            ? f.complete(requester, 'r1')
            : scenario == 'read'
                ? f.refresh(approver, upload: false)
                : f.respond(approver, 'r1');
        if (scenario == 'exhausted' || scenario == 'read') {
          await expectLater(action, throwsA(isA<GitHubException>()));
        } else {
          await action;
        }
      } finally {
        debugPrint = original;
      }
      final events = captured.map((e) => jsonDecode(e) as Map).toList();
      expect(events, isNotEmpty);
      final event = events.last;
      final failed = scenario == 'exhausted' || scenario == 'read';
      expect(event['state'], failed ? 'failed' : 'committed');
      expect(event['committedSha'], failed ? null : f.remote.sha);
      if (scenario != 'read') expect(event['readSha'], readSha);
      expect(event['elapsedMs'], isA<int>());
      expect(event['operation'], isA<String>());
      expect(event['deviceIdHash'], matches(RegExp(r'^[0-9a-f]{12}$')));
      if (scenario != 'read') {
        expect(event['requestIdHash'], matches(RegExp(r'^[0-9a-f]{12}$')));
      }
      expect(
          event['conflicts'],
          scenario == 'conflict'
              ? 2
              : scenario == 'exhausted'
                  ? 4
                  : 0);
      if (failed) {
        expect(events, everyElement(isNot(containsPair('state', 'committed'))));
        expect(event['httpStatus'], scenario == 'read' ? 403 : 409);
      }
      for (final secret in [
        'token-canary',
        'mnemonic-vault-body-canary',
        'Name trusted',
        base64Encode(f.root),
        'pendingDeviceApprovals',
        base64Encode(f.remote.bytes!)
      ]) {
        expect(captured.join(), isNot(contains(secret)));
      }
    });
  }

  for (final micros in [500000, 1500000, 2000000]) {
    test('server Date precision: request is $micros microseconds ahead',
        () async {
      await f.edit((r) {
        (r['pendingDeviceApprovals'] as List).single['requestedAt'] =
            now.add(Duration(microseconds: micros)).toIso8601String();
      });
      if (micros < 1000000) {
        await f.respond(approver, 'r1');
        final record = await requestRecord();
        expect(record['respondedAt'], record['requestedAt']);
        expect((await f.status(requester, 'r1')).isApproved, true);
        await f.complete(requester, 'r1');
      } else {
        await expectLater(f.respond(approver, 'r1'), throwsStateError);
        expect(f.remote.writes, 0);
      }
    });
  }

  for (final failure in [
    (401, 'http'),
    (403, 'http'),
    (404, 'missing_branch'),
    (429, 'rate_limit'),
    (500, 'http'),
    (null, 'timeout'),
    (null, 'network'),
    (null, 'invalid_data'),
  ]) {
    test('TC-OBS-004 read diagnostic classifies $failure without secrets',
        () async {
      await f.refresh(approver, upload: false);
      f.remote.readError = GitHubException('secret exception canary',
          statusCode: failure.$1, kind: failure.$2);
      final captured = <String>[];
      final original = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) captured.add(message);
      };
      try {
        await expectLater(f.refresh(approver, upload: false),
            throwsA(isA<GitHubException>()));
      } finally {
        debugPrint = original;
      }
      final event = jsonDecode(captured.last);
      expect(event['httpStatus'], failure.$1);
      expect(event['errorKind'], failure.$2);
      expect(event['state'], 'failed');
      expect(captured.join(), isNot(contains('secret exception canary')));
      expect(f.remote.attempts, isEmpty);
      expect(jsonDecode(approver.snapshot!)['stale'], true);
    });
  }

  for (final boundary in ['initialize', 'cache-read']) {
    test(
        'TC-MIG-006 unavailable $boundary fails before upload and releases queue',
        () async {
      final unavailable = _UnavailableStorage(boundary);
      unavailable.root = f.root;
      unavailable.deviceId = 'trusted';
      unavailable.name = 'Name trusted';
      await expectLater(f.refresh(unavailable), throwsStateError);
      expect(f.remote.attempts, isEmpty);
      // Failure must not leave the scope's serialized queue locked.
      await f.refresh(approver, upload: false);
      expect(jsonDecode(approver.snapshot!)['stale'], false);
    });
  }
}

class _UnavailableStorage extends MemoryRegistryStorage {
  final String boundary;
  _UnavailableStorage(this.boundary);
  @override
  Future<void> initialize() async {
    if (boundary == 'initialize') throw StateError('Storage unavailable');
  }

  @override
  Future<String?> getDeviceRegistrySnapshot() async =>
      throw StateError('Cache storage unavailable');
}
