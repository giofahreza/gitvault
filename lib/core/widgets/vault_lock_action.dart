import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';

class VaultLockAction extends ConsumerWidget {
  final bool compactOnly;
  final bool filled;
  final double railBreakpoint;

  const VaultLockAction({
    super.key,
    this.compactOnly = false,
    this.filled = false,
    this.railBreakpoint = 720,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final platform = defaultTargetPlatform;
    final supported = kIsWeb ||
        platform == TargetPlatform.windows ||
        platform == TargetPlatform.macOS ||
        platform == TargetPlatform.linux;
    if (!supported) return const SizedBox.shrink();
    if (compactOnly && MediaQuery.sizeOf(context).width >= railBreakpoint) {
      return const SizedBox.shrink();
    }

    Future<void> lock() async {
      FocusManager.instance.primaryFocus?.unfocus();

      var hasPin = false;
      try {
        hasPin = await ref.read(pinAuthProvider).isPinSetup();
      } catch (_) {
        // Treat unavailable PIN storage as no configured unlock method.
      }

      var hasBiometric = false;
      if (!hasPin && ref.read(biometricEnabledProvider)) {
        try {
          final biometricAuth = ref.read(biometricAuthProvider);
          hasBiometric = await biometricAuth.isSupported() &&
              await biometricAuth.isDeviceEnrolled();
        } catch (_) {
          // Unsupported or unavailable biometric APIs cannot unlock the vault.
        }
      }

      if (!context.mounted) return;
      if (!hasPin && !hasBiometric) {
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Cannot lock vault'),
            content: const Text(
              'Set up a PIN or biometric authentication before locking the vault.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Close'),
              ),
            ],
          ),
        );
        return;
      }

      ref.read(appLockSignalProvider.notifier).state++;
    }

    const icon = Icon(Icons.lock_outline);
    if (filled) {
      return IconButton.filledTonal(
        icon: icon,
        tooltip: 'Lock vault',
        onPressed: lock,
      );
    }

    return IconButton(
      icon: icon,
      tooltip: 'Lock vault',
      onPressed: lock,
    );
  }
}
