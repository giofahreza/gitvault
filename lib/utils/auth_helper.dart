import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers/providers.dart';

/// Authentication helper for biometric with PIN fallback
/// Returns true if authentication succeeded, false otherwise
class AuthHelper {
  /// Authenticate using biometric (fingerprint/face) with PIN as fallback
  ///
  /// Flow:
  /// 1. Check if biometric or PIN is enabled
  /// 2. Try biometric first if available
  /// 3. Fall back to PIN if biometric fails or unavailable
  /// 4. Show error if neither is enabled
  static Future<bool> authenticate({
    required BuildContext context,
    required WidgetRef ref,
    String reason = 'Authenticate to continue',
  }) async {
    final biometricEnabled = ref.read(biometricEnabledProvider);
    final pinEnabled = await ref.read(pinEnabledProvider.future);

    // Neither authentication method is enabled
    if (!biometricEnabled && !pinEnabled) {
      if (!context.mounted) return false;

      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Authentication Required'),
          content: const Text(
            'Please enable biometrics or PIN in Settings to use this feature.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return false;
    }

    // Try biometric first
    if (biometricEnabled) {
      final biometricAuth = ref.read(biometricAuthProvider);
      final supported = await biometricAuth.isSupported();

      if (supported) {
        final authenticated = await biometricAuth.authenticate(reason: reason);
        if (authenticated) {
          return true;
        }
        // If biometric failed but user has PIN, don't return false yet
        // Fall through to PIN authentication
      }
    }

    // Fall back to PIN (or use PIN if biometric not available)
    if (pinEnabled && context.mounted) {
      final result = await showDialog<bool>(
        context: context,
        builder: (ctx) => _PinVerifyDialog(),
      );
      return result ?? false;
    }

    return false;
  }
}

/// Simple PIN verification dialog
class _PinVerifyDialog extends ConsumerStatefulWidget {
  @override
  ConsumerState<_PinVerifyDialog> createState() => _PinVerifyDialogState();
}

class _PinVerifyDialogState extends ConsumerState<_PinVerifyDialog> {
  final _pinController = TextEditingController();
  bool _verifying = false;
  String? _error;

  @override
  void dispose() {
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    final pin = _pinController.text;
    if (pin.isEmpty) return;

    setState(() {
      _verifying = true;
      _error = null;
    });

    final pinAuth = ref.read(pinAuthProvider);
    final valid = await pinAuth.verifyPin(pin);

    if (valid) {
      if (mounted) Navigator.pop(context, true);
    } else {
      setState(() {
        _verifying = false;
        _error = 'Incorrect PIN';
        _pinController.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Enter PIN'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _pinController,
            keyboardType: TextInputType.number,
            obscureText: true,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'PIN',
              border: const OutlineInputBorder(),
              errorText: _error,
            ),
            onSubmitted: (_) => _verify(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _verifying ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _verifying ? null : _verify,
          child: _verifying
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Verify'),
        ),
      ],
    );
  }
}
