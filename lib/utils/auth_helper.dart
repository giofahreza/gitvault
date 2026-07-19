import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers/providers.dart';
import 'pointer_focus.dart';

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

      final pinConfigured = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _PinSetupDialog(reason: reason),
      );
      if (pinConfigured == true && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('PIN configured successfully')),
        );
        return true;
      }
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

/// PIN setup dialog used when a protected action has no unlock method yet.
class _PinSetupDialog extends ConsumerStatefulWidget {
  final String reason;

  const _PinSetupDialog({required this.reason});

  @override
  ConsumerState<_PinSetupDialog> createState() => _PinSetupDialogState();
}

class _PinSetupDialogState extends ConsumerState<_PinSetupDialog> {
  final _pinController = TextEditingController();
  final _confirmController = TextEditingController();
  final _pinFocus = FocusNode();
  final _confirmFocus = FocusNode();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _pinController.clear();
    _confirmController.clear();
    _pinController.dispose();
    _confirmController.dispose();
    _pinFocus.dispose();
    _confirmFocus.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;

    final pin = _pinController.text;
    final confirm = _confirmController.text;

    if (pin.length < 4) {
      setState(() => _error = 'PIN must be at least 4 digits');
      return;
    }
    if (pin.length > 6) {
      setState(() => _error = 'PIN must be 6 digits or fewer');
      return;
    }
    if (pin != confirm) {
      setState(() => _error = 'PINs do not match');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      await ref.read(pinAuthProvider).setupPin(pin);
      ref.invalidate(pinEnabledProvider);

      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Failed to save PIN: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Set Up PIN'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${widget.reason}. Set up a PIN now to continue on this device.',
          ),
          const SizedBox(height: 16),
          PointerFocus(
            focusNode: _pinFocus,
            child: TextField(
              controller: _pinController,
              focusNode: _pinFocus,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Enter PIN (4-6 digits)',
                border: OutlineInputBorder(),
                counterText: '',
              ),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              maxLength: 6,
              obscureText: true,
              enabled: !_saving,
              textInputAction: TextInputAction.next,
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              onSubmitted: (_) => _confirmFocus.requestFocus(),
            ),
          ),
          const SizedBox(height: 12),
          PointerFocus(
            focusNode: _confirmFocus,
            child: TextField(
              controller: _confirmController,
              focusNode: _confirmFocus,
              decoration: InputDecoration(
                labelText: 'Confirm PIN',
                border: const OutlineInputBorder(),
                counterText: '',
                errorText: _error,
              ),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              maxLength: 6,
              obscureText: true,
              enabled: !_saving,
              textInputAction: TextInputAction.done,
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              onSubmitted: (_) => _save(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Not Now'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Set Up PIN'),
        ),
      ],
    );
  }
}

/// Simple PIN verification dialog
class _PinVerifyDialog extends ConsumerStatefulWidget {
  @override
  ConsumerState<_PinVerifyDialog> createState() => _PinVerifyDialogState();
}

class _PinVerifyDialogState extends ConsumerState<_PinVerifyDialog> {
  final _pinController = TextEditingController();
  final _pinFocus = FocusNode();
  bool _verifying = false;
  String? _error;

  @override
  void dispose() {
    _pinController.clear();
    _pinController.dispose();
    _pinFocus.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    final pin = _pinController.text;
    if (pin.isEmpty) return;

    setState(() {
      _verifying = true;
      _error = null;
    });
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;

    final pinAuth = ref.read(pinAuthProvider);
    final valid = await pinAuth.verifyPin(pin);

    if (valid) {
      _pinController.clear();
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
          PointerFocus(
            focusNode: _pinFocus,
            child: TextField(
              controller: _pinController,
              focusNode: _pinFocus,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              maxLength: 6,
              obscureText: true,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'PIN',
                border: const OutlineInputBorder(),
                counterText: '',
                errorText: _error,
              ),
              onSubmitted: (_) => _verify(),
            ),
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
