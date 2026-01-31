import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/providers.dart';
import '../../utils/mnemonic_helper.dart';

/// Initial onboarding screen for first-time setup
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  int _currentStep = 0;
  bool _completing = false;
  Uint8List? _generatedRootKey;
  String? _generatedMnemonic; // NEW: Store the 24-word mnemonic
  bool _recoveryKeyCopied = false;
  bool _useExistingKey = false; // Toggle between new/existing key

  final _recoveryKeyController = TextEditingController(); // For inputting existing mnemonic

  @override
  void dispose() {
    _recoveryKeyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Welcome to GitVault'),
      ),
      body: Stepper(
        currentStep: _currentStep,
        onStepContinue: _completing
            ? null
            : () async {
                if (_currentStep < 2) {
                  setState(() => _currentStep++);
                } else {
                  _completeOnboarding();
                }
              },
        onStepCancel: _currentStep > 0 ? () => setState(() => _currentStep--) : null,
        controlsBuilder: (context, details) {
          final isLastStep = _currentStep == 2;
          return Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Row(
              children: [
                FilledButton(
                  onPressed: _completing ? null : details.onStepContinue,
                  child: _completing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : Text(isLastStep ? 'Get Started' : 'Continue'),
                ),
                if (_currentStep > 0 && !_completing) ...[
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: details.onStepCancel,
                    child: const Text('Back'),
                  ),
                ],
              ],
            ),
          );
        },
        steps: [
          // Step 0: Introduction
          Step(
            title: const Text('Welcome'),
            content: Builder(
              builder: (context) {
                final colorScheme = Theme.of(context).colorScheme;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.security, size: 64, color: colorScheme.primary),
                    const SizedBox(height: 16),
                    const Text(
                      'GitVault - Sovereign Password Manager',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 16),
                    const Text('Your passwords are encrypted on-device and synced to your private GitHub repository.'),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.info_outline, size: 16, color: colorScheme.primary),
                              const SizedBox(width: 8),
                              const Text('Optional Features', style: TextStyle(fontWeight: FontWeight.bold)),
                            ],
                          ),
                          const SizedBox(height: 8),
                          const Text('• Biometric lock (fingerprint/face)', style: TextStyle(fontSize: 13)),
                          const Text('• GitHub sync for backup', style: TextStyle(fontSize: 13)),
                          const SizedBox(height: 8),
                          Text(
                            'You can enable these later in Settings.',
                            style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
            isActive: _currentStep >= 0,
          ),
          // Step 1: Recovery Kit — generate key when step becomes active OR input existing key
          Step(
            title: const Text('Recovery Kit'),
            content: Builder(
              builder: (context) {
                // Generate mnemonic when this step is displayed (only if creating new)
                if (_currentStep >= 1 && _generatedMnemonic == null && !_useExistingKey) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (_generatedMnemonic == null && !_useExistingKey) {
                      setState(() {
                        final result = MnemonicHelper.generateMnemonic();
                        _generatedMnemonic = result.mnemonic;
                        _generatedRootKey = result.rootKey;
                      });
                    }
                  });
                }
                final colorScheme = Theme.of(context).colorScheme;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.vpn_key, size: 48, color: colorScheme.primary),
                    const SizedBox(height: 16),

                    // Toggle between new and existing key
                    Row(
                      children: [
                        Expanded(
                          child: SegmentedButton<bool>(
                            segments: const [
                              ButtonSegment(value: false, label: Text('Create New'), icon: Icon(Icons.add)),
                              ButtonSegment(value: true, label: Text('Use Existing'), icon: Icon(Icons.input)),
                            ],
                            selected: {_useExistingKey},
                            onSelectionChanged: (Set<bool> selected) {
                              setState(() {
                                _useExistingKey = selected.first;
                                if (!_useExistingKey) {
                                  _recoveryKeyController.clear();
                                } else {
                                  _generatedRootKey = null;
                                  _generatedMnemonic = null;
                                  _recoveryKeyCopied = false;
                                }
                              });
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // Show different UI based on mode
                    if (!_useExistingKey) ...[
                      const Text(
                        'IMPORTANT: Save your recovery kit!',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      const Text('If you lose all your devices, this is your only way to recover your data.'),
                      const SizedBox(height: 16),
                      if (_generatedMnemonic != null) ...[
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: colorScheme.outline),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Your 24-Word Recovery Phrase:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                              const SizedBox(height: 8),
                              SelectableText(
                                MnemonicHelper.formatMnemonicForDisplay(_generatedMnemonic!),
                                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: _generatedMnemonic!));
                            setState(() => _recoveryKeyCopied = true);
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Recovery phrase copied to clipboard')),
                            );
                          },
                          icon: Icon(_recoveryKeyCopied ? Icons.check : Icons.copy),
                          label: Text(_recoveryKeyCopied ? 'Copied!' : 'Copy Recovery Phrase'),
                        ),
                      ],
                      const SizedBox(height: 8),
                      Text('Write down these 24 words in order and store them safely.', style: TextStyle(color: colorScheme.onSurfaceVariant)),
                    ] else ...[
                      const Text(
                        'Restore from Recovery Phrase',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      const Text('Enter your 24-word recovery phrase to restore your vault on this device.'),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _recoveryKeyController,
                        decoration: const InputDecoration(
                          labelText: 'Recovery Phrase',
                          hintText: 'word1 word2 word3 ...',
                          border: OutlineInputBorder(),
                          helperText: 'Enter or paste your 24 words separated by spaces',
                        ),
                        maxLines: 4,
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'This 24-word phrase was shown to you when you first set up GitVault.',
                        style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ],
                );
              },
            ),
            isActive: _currentStep >= 1,
          ),
          // Step 2: Confirm
          Step(
            title: const Text('All Set'),
            content: Builder(
              builder: (context) {
                final colorScheme = Theme.of(context).colorScheme;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.check_circle, size: 48, color: colorScheme.tertiary),
                    const SizedBox(height: 16),
                    const Text(
                      'You\'re ready to go!',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Next Steps (Optional):',
                            style: TextStyle(fontWeight: FontWeight.bold, color: colorScheme.primary),
                          ),
                          const SizedBox(height: 8),
                          const Text('• Enable biometric lock in Settings', style: TextStyle(fontSize: 13)),
                          const Text('• Set up GitHub sync for backup', style: TextStyle(fontSize: 13)),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
            isActive: _currentStep >= 2,
          ),
        ],
      ),
    );
  }

  Future<void> _completeOnboarding() async {
    setState(() => _completing = true);

    try {
      final keyStorage = ref.read(keyStorageProvider);
      await keyStorage.initialize(); // Initialize Hive box

      // Determine which key to use
      Uint8List? rootKey;

      if (_useExistingKey) {
        // Parse recovery phrase from input
        final inputMnemonic = MnemonicHelper.normalizeMnemonic(_recoveryKeyController.text);
        if (inputMnemonic.isEmpty) {
          throw Exception('Please enter your 24-word recovery phrase');
        }

        if (!MnemonicHelper.isValidMnemonic(inputMnemonic)) {
          throw Exception('Invalid recovery phrase. Please check your words and try again.');
        }

        rootKey = MnemonicHelper.mnemonicToRootKey(inputMnemonic);
      } else {
        // Use the key generated at the recovery step
        if (_generatedRootKey == null) {
          throw Exception('Recovery phrase not generated. Please go back and try again.');
        }
        rootKey = _generatedRootKey!;
      }

      // Try to store root key with timeout and retry logic
      bool stored = false;
      int retries = 3;

      for (int i = 0; i < retries && !stored; i++) {
        try {
          if (i > 0) {
            // Clear secure storage on retry to fix KeyStore corruption
            await keyStorage.wipeAllKeys();
            await Future.delayed(Duration(milliseconds: 500));
          }

          await keyStorage.storeRootKey(rootKey).timeout(
            Duration(seconds: 10),
            onTimeout: () => throw Exception('Storage timeout - KeyStore may be full'),
          );
          stored = true;
        } catch (e) {
          if (i == retries - 1) {
            throw Exception('Failed to store encryption key after $retries attempts: $e');
          }
          // Wait before retry
          await Future.delayed(Duration(milliseconds: 500 * (i + 1)));
        }
      }

      // Disable biometrics by default (user can enable later in Settings)
      ref.read(biometricEnabledProvider.notifier).state = false;

      ref.invalidate(isVaultSetupProvider);
    } catch (e) {
      setState(() => _completing = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Setup failed: $e'),
            duration: Duration(seconds: 8),
            action: SnackBarAction(
              label: 'Retry',
              onPressed: _completeOnboarding,
            ),
          ),
        );
      }
    }
  }
}
