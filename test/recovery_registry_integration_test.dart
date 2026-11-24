import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitvault/core/services/github_service.dart';
import 'package:gitvault/features/settings/recovery_approval_dialog.dart';

import 'support/memory_registry_storage.dart';
import 'support/registry_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late RegistryFixture f;
  late MemoryRegistryStorage source, target;
  late String id;
  bool? closed;
  var completions = 0;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester,
      {Future<void> Function()? beforeComplete}) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
      builder: (context) => TextButton(
        onPressed: () async {
          closed = await showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (_) => RecoveryApprovalDialog(
              approvalId: id,
              check: (request) => f.status(target, request),
              complete: (request) async {
                completions++;
                await beforeComplete?.call();
                await f.complete(target, request);
              },
              requestAgain: () => f.request(target),
              recoverWithNewToken: (_) async => false,
            ),
          );
        },
        child: const Text('Open'),
      ),
    ))));
    await tester.tap(find.text('Open'));
    await tester.pump();
    await settle(tester);
  }

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.giofahreza.gitvault/ime'),
      (_) async => null,
    );
    f = RegistryFixture();
    // Whole-second server dates deliberately exercise fast consecutive requests.
    f.remote.serverTime = DateTime.utc(2030, 1, 1);
    await f.seed({
      'devices': [
        {'deviceId': 'source', 'registrationMethod': 'setup'},
      ]
    });
    source = await f.device('source');
    target = await f.device('target', method: 'recovery');
    id = await f.request(target);
    closed = null;
    completions = 0;
  });

  testWidgets(
      'TC-MODAL-001 registry request, response and completion close modal',
      (tester) async {
    await open(tester);
    expect(find.textContaining('Waiting for approval'), findsOneWidget);
    await tester.runAsync(() => f.respond(source, id));
    await tester.pump(const Duration(seconds: 3));
    await settle(tester);
    expect(closed, true);
    expect(find.byType(RecoveryApprovalDialog), findsNothing);
    final registry = (await tester.runAsync(f.decode))!;
    expect(
        registry['devices'],
        contains(allOf(
          containsPair('deviceId', 'target'),
          containsPair('recoveryApprovalId', id),
          containsPair('registrationMethod', 'recovery_approved'),
        )));
    expect(completions, 1);
  });

  testWidgets('TC-MODAL-003 timely real response completes when observed late',
      (tester) async {
    await f.respond(source, id);
    f.remote.serverTime = f.remote.serverTime!.add(const Duration(minutes: 1));
    await open(tester);
    expect(closed, true);
    final registry = (await tester.runAsync(f.decode))!;
    expect((registry['pendingDeviceApprovals'] as List).single['completedAt'],
        isNotNull);
  });

  testWidgets('TC-MODAL-004 real 409 rebases completion before modal dismissal',
      (tester) async {
    await f.respond(source, id);
    f.remote.beforeWrite =
        () => f.edit((r) => r['concurrentHeartbeat'] = 'keep');
    await open(tester);
    expect(closed, true);
    expect(f.remote.conflicts, 1);
    final registry = (await tester.runAsync(f.decode))!;
    expect(registry['concurrentHeartbeat'], 'keep');
    expect((registry['pendingDeviceApprovals'] as List).single['completedAt'],
        isNotNull);
  });

  testWidgets(
      'TC-MODAL-005 old writer overwrites approval without false success',
      (tester) async {
    await f.respond(source, id);
    await open(tester,
        beforeComplete: () => f.edit((r) {
              final request =
                  (r['pendingDeviceApprovals'] as List).single as Map;
              request['status'] = 'pending';
              request.remove('respondedAt');
            }));
    expect(closed, null);
    expect(find.textContaining('Temporarily unable'), findsOneWidget);
    final registry = (await tester.runAsync(f.decode))!;
    expect((registry['devices'] as List),
        isNot(contains(containsPair('deviceId', 'target'))));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(closed, false);
  });

  testWidgets(
      'TC-MODAL-006 late remote approval is terminal without registration',
      (tester) async {
    await f.edit((r) {
      final request = (r['pendingDeviceApprovals'] as List).single as Map;
      request['status'] = 'approved';
      request['respondedAt'] = f.remote.serverTime!
          .add(const Duration(seconds: 31))
          .toIso8601String();
    });
    f.remote.serverTime = f.remote.serverTime!.add(const Duration(seconds: 40));
    final writes = f.remote.writes;
    await open(tester);
    expect(find.textContaining('Recovery request expired'), findsOneWidget);
    expect(completions, 0);
    expect(f.remote.writes, writes);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets(
      'TC-MODAL-008 repeated real offline polls stop and recover safely',
      (tester) async {
    f.remote.readError = GitHubException('Offline', kind: 'network');
    await open(tester);
    for (var tick = 0; tick < 12; tick++) {
      await tester.pump(const Duration(seconds: 3));
      await settle(tester);
    }
    expect(find.textContaining('Could not confirm'), findsOneWidget);
    final reads = f.remote.reads;
    await tester.pump(const Duration(seconds: 30));
    await settle(tester);
    expect(f.remote.reads, reads);
    expect(completions, 0);
    f.remote.readError = null;
    f.remote.serverTime = f.remote.serverTime!.add(const Duration(minutes: 1));
    await tester.tap(find.text('Check Approval'));
    await settle(tester);
    expect(find.textContaining('Recovery request expired'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets(
      'TC-MODAL-009 real completion outage retries once after reconnect',
      (tester) async {
    await f.respond(source, id);
    var fail = true;
    await open(tester, beforeComplete: () async {
      f.remote.writeError =
          fail ? GitHubException('Offline', kind: 'network') : null;
    });
    expect(find.byType(RecoveryApprovalDialog), findsOneWidget);
    expect(closed, null);
    fail = false;
    await tester.tap(find.text('Check Approval'));
    await settle(tester);
    expect(closed, true);
    final registry = (await tester.runAsync(f.decode))!;
    expect(
        (registry['devices'] as List)
            .cast<Map>()
            .where((d) => d['deviceId'] == 'target'),
        hasLength(1));
    expect(completions, 2);
  });

  for (final denied in [false, true]) {
    testWidgets(
        'TC-MODAL-013 cancel directly from ${denied ? 'denied' : 'expired'}',
        (tester) async {
      if (denied) {
        await f.respond(source, id, approved: false);
      } else {
        f.remote.serverTime =
            f.remote.serverTime!.add(const Duration(minutes: 1));
      }
      final writes = f.remote.writes;
      await open(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(closed, false);
      expect(completions, 0);
      expect(f.remote.writes, writes);
      expect(target.method, 'recovery');
    });
  }
}
