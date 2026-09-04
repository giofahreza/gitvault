import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitvault/core/auth/pin_auth.dart';
import 'package:gitvault/core/crypto/key_storage.dart';
import 'package:gitvault/core/providers/providers.dart';
import 'package:gitvault/core/widgets/vault_lock_action.dart';

void main() {
  testWidgets('desktop lock action is visible and requests a vault lock',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final container = ProviderContainer(
      overrides: [
        pinAuthProvider.overrideWithValue(_StubPinAuth(configured: true)),
      ],
    );
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
      await tester.pumpAndSettle();

      expect(container.read(appLockSignalProvider), 1);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('lock action explains when no unlock method is configured',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final container = ProviderContainer(
      overrides: [
        pinAuthProvider.overrideWithValue(_StubPinAuth(configured: false)),
        biometricEnabledProvider.overrideWith((ref) => false),
      ],
    );
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

      await tester.tap(find.byTooltip('Lock vault'));
      await tester.pumpAndSettle();

      expect(container.read(appLockSignalProvider), 0);
      expect(find.text('Cannot lock vault'), findsOneWidget);
      expect(
        find.text(
          'Set up a PIN or biometric authentication before locking the vault.',
        ),
        findsOneWidget,
      );
      expect(find.text('Close'), findsOneWidget);

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Cannot lock vault'), findsNothing);
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

class _StubPinAuth extends PinAuth {
  final bool configured;

  _StubPinAuth({required this.configured}) : super(keyStorage: KeyStorage());

  @override
  Future<bool> isPinSetup() async => configured;
}
