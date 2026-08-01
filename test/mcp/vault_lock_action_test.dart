import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitvault/core/providers/providers.dart';
import 'package:gitvault/core/widgets/vault_lock_action.dart';

void main() {
  testWidgets('desktop lock action is visible and requests a vault lock',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final container = ProviderContainer();
    addTearDown(container.dispose);

    try {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: VaultLockAction(),
            ),
          ),
        ),
      );

      expect(find.byTooltip('Lock vault'), findsOneWidget);
      expect(container.read(appLockSignalProvider), 0);

      await tester.tap(find.byTooltip('Lock vault'));
      await tester.pump();

      expect(container.read(appLockSignalProvider), 1);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('native mobile platforms do not show the desktop lock action',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;

    try {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: VaultLockAction(),
            ),
          ),
        ),
      );

      expect(find.byTooltip('Lock vault'), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
