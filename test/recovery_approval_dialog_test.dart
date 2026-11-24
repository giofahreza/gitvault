import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitvault/data/repositories/sync_engine.dart';
import 'package:gitvault/features/settings/recovery_approval_dialog.dart';

Future<void> openDialog(
  WidgetTester tester, {
  required Future<DeviceApprovalStatus> Function(String) check,
  Future<void> Function(String)? complete,
  Future<String> Function()? requestAgain,
  Future<bool> Function(String)? newToken,
  void Function(bool?)? closed,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              final result = await showDialog<bool>(
                context: context,
                barrierDismissible: false,
                builder: (_) => RecoveryApprovalDialog(
                  approvalId: 'request-1',
                  check: check,
                  complete: complete ?? (_) async {},
                  requestAgain: requestAgain ?? () async => 'request-2',
                  recoverWithNewToken: newToken ?? (_) async => false,
                ),
              );
              closed?.call(result);
            },
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

void main() {
  testWidgets('countdown uses remaining lifetime confirmed by remote polling',
      (tester) async {
    await openDialog(tester,
        check: (_) async =>
            DeviceApprovalStatus.pending({}, remainingSeconds: 5));
    expect(find.text('Waiting for approval... 5 seconds left'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });
  testWidgets(
      'modal stays until durable completion then closes independently of restore',
      (tester) async {
    final commit = Completer<void>();
    bool? result;
    await openDialog(
      tester,
      check: (_) async => DeviceApprovalStatus.approved({}),
      complete: (_) => commit.future,
      closed: (value) => result = value,
    );
    expect(
      find.text('Approval received. Completing registration...'),
      findsOneWidget,
    );
    expect(find.byType(RecoveryApprovalDialog), findsOneWidget);
    commit.complete();
    await tester.pumpAndSettle();
    expect(result, true);
    expect(find.byType(RecoveryApprovalDialog), findsNothing);
  });

  testWidgets('next poll sees approval committed after previous pending read',
      (tester) async {
    var polls = 0;
    var completions = 0;
    await openDialog(
      tester,
      check: (_) async => ++polls == 1
          ? DeviceApprovalStatus.pending({})
          : DeviceApprovalStatus.approved({}),
      complete: (_) async {
        completions++;
      },
    );
    expect(find.textContaining('Waiting for approval'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(completions, 1);
    expect(find.byType(RecoveryApprovalDialog), findsNothing);
  });

  testWidgets('completion failure is recoverable without false dismissal',
      (tester) async {
    var attempts = 0;
    await openDialog(
      tester,
      check: (_) async => DeviceApprovalStatus.approved({}),
      complete: (_) async {
        if (++attempts == 1) throw StateError('offline');
      },
    );
    expect(find.textContaining('Temporarily unable'), findsOneWidget);
    expect(find.byType(RecoveryApprovalDialog), findsOneWidget);
    await tester.tap(find.text('Check Approval'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.byType(RecoveryApprovalDialog), findsNothing);
  });

  for (final denied in [false, true]) {
    testWidgets(
        '${denied ? 'denied' : 'expired'} stops polling and retry uses new request ID',
        (tester) async {
      final ids = <String>[];
      await openDialog(
        tester,
        check: (id) async {
          ids.add(id);
          return id == 'request-2'
              ? DeviceApprovalStatus.pending({})
              : denied
                  ? DeviceApprovalStatus.denied({})
                  : DeviceApprovalStatus.expired({});
        },
      );
      expect(find.text('Request Approval Again'), findsOneWidget);
      final before = ids.length;
      await tester.pump(const Duration(seconds: 60));
      expect(ids.length, before);
      await tester.tap(find.text('Request Approval Again'));
      await tester.pumpAndSettle();
      expect(ids.last, 'request-2');
      expect(find.textContaining('Waiting for approval'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    });
  }

  testWidgets(
      'polling errors stay retryable and successful check replaces error',
      (tester) async {
    var unavailable = true;
    await openDialog(
      tester,
      check: (_) async {
        if (unavailable) throw StateError('offline');
        return DeviceApprovalStatus.pending({});
      },
    );
    expect(find.textContaining('Could not confirm'), findsOneWidget);
    unavailable = false;
    await tester.tap(find.text('Check Approval'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not confirm'), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('automatic checks cannot overlap an in-flight manual check',
      (tester) async {
    final response = Completer<DeviceApprovalStatus>();
    var checks = 0;
    await openDialog(
      tester,
      check: (_) {
        checks++;
        return response.future;
      },
    );
    final button = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Check Approval'),
    );
    expect(button.onPressed, null);
    await tester.pump(const Duration(seconds: 6));
    expect(checks, 1);
    response.complete(DeviceApprovalStatus.expired({}));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('resume checks approval immediately after suspended polling',
      (tester) async {
    var approved = false;
    await openDialog(
      tester,
      check: (_) async => approved
          ? DeviceApprovalStatus.approved({})
          : DeviceApprovalStatus.pending({}),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    approved = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.byType(RecoveryApprovalDialog), findsNothing);
  });

  testWidgets('disposal during remote read never calls setState afterward',
      (tester) async {
    final response = Completer<DeviceApprovalStatus>();
    await openDialog(tester, check: (_) => response.future);
    await tester.pumpWidget(const SizedBox());
    response.complete(DeviceApprovalStatus.approved({}));
    await tester.pump();
    expect(tester.takeException(), null);
  });

  testWidgets('new token flow pauses polling and closes without second restore',
      (tester) async {
    var checks = 0;
    bool? result;
    await openDialog(
      tester,
      check: (_) async {
        checks++;
        return DeviceApprovalStatus.expired({});
      },
      newToken: (id) async {
        expect(id, 'request-1');
        return true;
      },
      closed: (value) => result = value,
    );
    await tester.tap(find.text('Use New Token'));
    await tester.pumpAndSettle();
    expect(result, false);
    expect(checks, 1);
  });

  testWidgets('failed retry preserves terminal state and can be retried again',
      (tester) async {
    await openDialog(
      tester,
      check: (_) async => DeviceApprovalStatus.expired({}),
      requestAgain: () async => throw StateError('offline'),
    );
    await tester.tap(find.text('Request Approval Again'));
    await tester.pumpAndSettle();
    expect(
      find.text('Could not request approval. Please retry.'),
      findsOneWidget,
    );
    expect(find.text('Request Approval Again'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });
}
