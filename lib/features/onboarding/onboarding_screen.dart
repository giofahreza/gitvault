import 'dart:typed_data';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart'
    show KeyDownEvent, KeyEvent, KeyEventResult, LogicalKeyboardKey;

import '../../core/providers/providers.dart';
import '../device_linking/link_device_screen.dart';
import '../../utils/clipboard_feedback.dart';
import '../../utils/mnemonic_helper.dart';
import '../../utils/pointer_focus.dart';
import '../../utils/recovery_phrase_grid.dart';

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

  final _recoveryKeyController =
      TextEditingController(); // For inputting existing mnemonic
  final _recoveryKeyFocus = FocusNode();
  final _screenFocus = FocusNode(debugLabel: 'OnboardingScreenFocus');
  late final ScrollController _stepperScrollController;

  @override
  void initState() {
    super.initState();
    _stepperScrollController = ScrollController();
    WidgetsBinding.instance.addPostFrameCallback((_) => _requestScreenFocus());
  }

  @override
  void dispose() {
    _recoveryKeyController.clear();
    _recoveryKeyController.dispose();
    _recoveryKeyFocus.dispose();
    _screenFocus.dispose();
    _stepperScrollController.dispose();
    super.dispose();
  }

  bool get _showPersistentScrollbar =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;

  void _requestScreenFocus() {
    if (!mounted) return;
    if (_recoveryKeyFocus.hasFocus) return;
    FocusScope.of(context).requestFocus(_screenFocus);
  }

  void _scrollStepperToStart() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_stepperScrollController.hasClients) return;
      _stepperScrollController.animateTo(
        _stepperScrollController.position.minScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _moveToStep(int step) {
    setState(() => _currentStep = step);
    WidgetsBinding.instance.addPostFrameCallback((_) => _requestScreenFocus());
    _scrollStepperToStart();
  }

  Future<void> _linkFromTrustedDevice() async {
    if (_completing) return;

    final linked = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => const LinkDeviceScreen(
          initialIsSource: false,
          allowRoleSwitch: false,
        ),
      ),
    );

    if (!mounted) return;
    if (linked == true) {
      ref.invalidate(isVaultSetupProvider);
      return;
    }

    _requestScreenFocus();
  }

  Future<void> _handleContinue() async {
    if (_completing) return;

    if (_currentStep < 2) {
      _moveToStep(_currentStep + 1);
      return;
    }

    await _completeOnboarding();
  }

  KeyEventResult _handleKeyboard(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || _completing) {
      return KeyEventResult.ignored;
    }
    if (_recoveryKeyFocus.hasFocus) {
      return KeyEventResult.ignored;
    }

    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _handleContinue();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape && _currentStep > 0) {
      _moveToStep(_currentStep - 1);
      return KeyEventResult.handled;
    }

    if (!_stepperScrollController.hasClients) {
      return KeyEventResult.ignored;
    }

    final position = _stepperScrollController.position;
    final pageStep = position.viewportDimension * 0.85;
    const lineStep = 64.0;
    double? target;

    if (key == LogicalKeyboardKey.end) {
      target = position.maxScrollExtent;
    } else if (key == LogicalKeyboardKey.home) {
      target = position.minScrollExtent;
    } else if (key == LogicalKeyboardKey.pageDown) {
      target = position.pixels + pageStep;
    } else if (key == LogicalKeyboardKey.pageUp) {
      target = position.pixels - pageStep;
    } else if (key == LogicalKeyboardKey.arrowDown) {
      target = position.pixels + lineStep;
    } else if (key == LogicalKeyboardKey.arrowUp) {
      target = position.pixels - lineStep;
    }

    if (target != null) {
      final clamped = target
          .clamp(
            position.minScrollExtent,
            position.maxScrollExtent,
          )
          .toDouble();
      _stepperScrollController.animateTo(
        clamped,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
      );
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Welcome to GitVault'),
      ),
      body: Focus(
        focusNode: _screenFocus,
        autofocus: true,
        onKeyEvent: _handleKeyboard,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width =
                constraints.maxWidth > 760 ? 760.0 : constraints.maxWidth;

            return Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: width,
                height: constraints.maxHeight,
                child: Scrollbar(
                  controller: _stepperScrollController,
                  thumbVisibility: _showPersistentScrollbar,
                  interactive: true,
                  child: Stepper(
                    controller: _stepperScrollController,
                    currentStep: _currentStep,
                    onStepContinue: _completing ? null : _handleContinue,
                    onStepCancel: _currentStep > 0
                        ? () => _moveToStep(_currentStep - 1)
                        : null,
                    controlsBuilder: (context, details) {
                      final isLastStep = _currentStep == 2;
                      final narrow = MediaQuery.sizeOf(context).width < 520;
                      final continueButton = Semantics(
                        button: true,
                        label: isLastStep ? 'Get Started' : 'Continue',
                        child: FilledButton(
                          onPressed:
                              _completing ? null : details.onStepContinue,
                          child: _completing
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white),
                                )
                              : Text(isLastStep ? 'Get Started' : 'Continue'),
                        ),
                      );
                      final backButton = Semantics(
                        button: true,
                        label: 'Back',
                        child: TextButton(
                          onPressed: details.onStepCancel,
                          child: const Text('Back'),
                        ),
                      );

                      if (narrow) {
                        return Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              continueButton,
                              if (_currentStep > 0 && !_completing) ...[
                                const SizedBox(height: 8),
                                backButton,
                              ],
                            ],
                          ),
                        );
                      }

                      return Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Row(
                          children: [
                            continueButton,
                            if (_currentStep > 0 && !_completing) ...[
                              const SizedBox(width: 8),
                              backButton,
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
                                Icon(Icons.security,
                                    size: 64, color: colorScheme.primary),
                                const SizedBox(height: 16),
                                const Text(
                                  'GitVault - Sovereign Password Manager',
                                  style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold),
                                ),
                                const SizedBox(height: 16),
                                const Text(
                                    'Your passwords are encrypted on-device and synced to your private GitHub repository.'),
                                const SizedBox(height: 12),
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: colorScheme.surfaceContainerHighest,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Icon(Icons.info_outline,
                                              size: 16,
                                              color: colorScheme.primary),
                                          const SizedBox(width: 8),
                                          const Text('Optional Features',
                                              style: TextStyle(
                                                  fontWeight: FontWeight.bold)),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      const Text(
                                          '• PIN lock for secure web unlock',
                                          style: TextStyle(fontSize: 13)),
                                      const Text(
                                          '• Biometric lock (fingerprint/face)',
                                          style: TextStyle(fontSize: 13)),
                                      const Text('• GitHub sync for backup',
                                          style: TextStyle(fontSize: 13)),
                                      const SizedBox(height: 8),
                                      Text(
                                        'You can enable these later in Settings.',
                                        style: TextStyle(
                                            fontSize: 12,
                                            color:
                                                colorScheme.onSurfaceVariant),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 16),
                                Semantics(
                                  button: true,
                                  label: 'Link from trusted device',
                                  child: FilledButton.tonalIcon(
                                    onPressed: _completing
                                        ? null
                                        : _linkFromTrustedDevice,
                                    icon: const Icon(Icons.phonelink_setup),
                                    label: const Text(
                                      'Link from Trusted Device',
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Already using GitVault? Approve this browser or phone from a trusted device instead of creating a new vault.',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: colorScheme.onSurfaceVariant,
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
                            if (_currentStep >= 1 &&
                                _generatedMnemonic == null &&
                                !_useExistingKey) {
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                if (_generatedMnemonic == null &&
                                    !_useExistingKey) {
                                  setState(() {
                                    final result =
                                        MnemonicHelper.generateMnemonic();
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
                                Icon(Icons.vpn_key,
                                    size: 48, color: colorScheme.primary),
                                const SizedBox(height: 16),

                                // Toggle between new and existing key
                                Row(
                                  children: [
                                    Expanded(
                                      child: SegmentedButton<bool>(
                                        segments: const [
                                          ButtonSegment(
                                            value: false,
                                            label: Text('Create New'),
                                            icon: Icon(Icons.add),
                                          ),
                                          ButtonSegment(
                                            value: true,
                                            label: Text('Use Existing'),
                                            icon: Icon(Icons.input),
                                          ),
                                        ],
                                        selected: {_useExistingKey},
                                        onSelectionChanged:
                                            (Set<bool> selected) {
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
                                    style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold),
                                  ),
                                  const SizedBox(height: 8),
                                  const Text(
                                      'If you lose all your devices, this is your only way to recover your data.'),
                                  const SizedBox(height: 16),
                                  if (_generatedMnemonic != null) ...[
                                    Container(
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(
                                        color:
                                            colorScheme.surfaceContainerHighest,
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                            color: colorScheme.outline),
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          const Text(
                                              'Your 24-Word Recovery Phrase:',
                                              style: TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 12)),
                                          const SizedBox(height: 8),
                                          Semantics(
                                            container: true,
                                            label:
                                                'Your 24-word recovery phrase: ${MnemonicHelper.formatMnemonicForDisplay(_generatedMnemonic!)}',
                                            child: ExcludeSemantics(
                                              child: RecoveryPhraseGrid(
                                                words: _generatedMnemonic!
                                                    .split(' '),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    OutlinedButton.icon(
                                      onPressed: () async {
                                        final copied =
                                            await copyTextWithFeedback(
                                          context,
                                          text: _generatedMnemonic!,
                                          successMessage:
                                              'Recovery phrase copied to clipboard',
                                          failureMessage:
                                              'Could not copy recovery phrase. Copy the words manually instead.',
                                        );
                                        if (copied && mounted) {
                                          setState(
                                              () => _recoveryKeyCopied = true);
                                        }
                                      },
                                      icon: Icon(_recoveryKeyCopied
                                          ? Icons.check
                                          : Icons.copy),
                                      label: Text(_recoveryKeyCopied
                                          ? 'Copied!'
                                          : 'Copy Recovery Phrase'),
                                    ),
                                  ],
                                  const SizedBox(height: 8),
                                  Text(
                                      'Write down these 24 words in order and store them safely.',
                                      style: TextStyle(
                                          color: colorScheme.onSurfaceVariant)),
                                ] else ...[
                                  const Text(
                                    'Restore from Recovery Phrase',
                                    style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold),
                                  ),
                                  const SizedBox(height: 8),
                                  const Text(
                                      'Enter your 24-word recovery phrase to restore your vault on this device.'),
                                  const SizedBox(height: 16),
                                  PointerFocus(
                                    focusNode: _recoveryKeyFocus,
                                    child: TextField(
                                      controller: _recoveryKeyController,
                                      focusNode: _recoveryKeyFocus,
                                      decoration: const InputDecoration(
                                        labelText: 'Recovery Phrase',
                                        hintText: 'word1 word2 word3 ...',
                                        border: OutlineInputBorder(),
                                        helperText:
                                            'Enter or paste your 24 words separated by spaces',
                                      ),
                                      maxLines: 4,
                                      style: const TextStyle(
                                          fontFamily: 'monospace',
                                          fontSize: 12),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    'After setup, connect GitHub Sync to request approval from another trusted device. If all devices are lost, GitVault will ask for a newly generated GitHub token.',
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: colorScheme.onSurfaceVariant),
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
                                Icon(Icons.check_circle,
                                    size: 48, color: colorScheme.tertiary),
                                const SizedBox(height: 16),
                                const Text(
                                  'You\'re ready to go!',
                                  style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold),
                                ),
                                const SizedBox(height: 16),
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: colorScheme.surfaceContainerHighest,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Next Steps (Optional):',
                                        style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            color: colorScheme.primary),
                                      ),
                                      const SizedBox(height: 8),
                                      const Text(
                                          '• Set up PIN Lock in Settings',
                                          style: TextStyle(fontSize: 13)),
                                      const Text(
                                          '• Enable biometric lock in Settings',
                                          style: TextStyle(fontSize: 13)),
                                      const Text(
                                          '• Set up GitHub sync for backup',
                                          style: TextStyle(fontSize: 13)),
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
                ),
              ),
            );
          },
        ),
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
        final inputMnemonic =
            MnemonicHelper.normalizeMnemonic(_recoveryKeyController.text);
        if (inputMnemonic.isEmpty) {
          throw Exception('Please enter your 24-word recovery phrase');
        }

        if (!MnemonicHelper.isValidMnemonic(inputMnemonic)) {
          throw Exception(
              'Invalid recovery phrase. Please check your words and try again.');
        }

        rootKey = MnemonicHelper.mnemonicToRootKey(inputMnemonic);
      } else {
        // Use the key generated at the recovery step
        if (_generatedRootKey == null) {
          throw Exception(
              'Recovery phrase not generated. Please go back and try again.');
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
                onTimeout: () =>
                    throw Exception('Storage timeout - KeyStore may be full'),
              );
          await keyStorage.storeDeviceRegistrationMethod(
            _useExistingKey ? 'recovery' : 'setup',
          );
          stored = true;
        } catch (e) {
          if (i == retries - 1) {
            throw Exception(
                'Failed to store encryption key after $retries attempts: $e');
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
