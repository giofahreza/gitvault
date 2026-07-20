import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'core/auth/biometric_auth.dart';
import 'core/providers/providers.dart';
import 'core/services/autofill_request_handler.dart';
import 'core/services/github_service.dart';
import 'core/services/background_sync_service.dart';
import 'core/services/device_identity_service.dart';
import 'core/services/persistent_ssh_service.dart';
import 'core/theme/app_theme.dart';
import 'core/widgets/web_lock_action.dart';
import 'data/models/vault_entry.dart';
import 'data/repositories/sync_engine.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/vault/vault_screen.dart';
import 'features/totp/totp_codes_page.dart';
import 'features/ssh/ssh_screen.dart';
import 'features/notes/notes_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/autofill/autofill_select_screen.dart';
import 'utils/pointer_focus.dart';

/// Extract the registered domain from a URL string (strips www.).
String? _extractDomain(String? url) {
  if (url == null || url.isEmpty) return null;
  try {
    final uri = Uri.parse(url.startsWith('http') ? url : 'https://$url');
    return uri.host.replaceFirst('www.', '');
  } catch (_) {
    return null;
  }
}

/// Filter vault entries that match the given autofill package/domain context.
List<VaultEntry> _filterForAutofill(
  List<VaultEntry> entries,
  String? packageName,
  String? domain,
) {
  return entries.where((entry) {
    final title = entry.title.toLowerCase();
    final notes = (entry.notes ?? '').toLowerCase();
    final entryUrl = (entry.url ?? '').toLowerCase();

    if (domain != null && domain.isNotEmpty) {
      final domainLower = domain.toLowerCase();
      // Precise: compare extracted domains
      final entryDomain = _extractDomain(entry.url);
      if (entryDomain != null &&
          (domainLower.contains(entryDomain) ||
              entryDomain.contains(domainLower))) {
        return true;
      }
      // Fallback: substring matching on title / notes / url
      if (title.contains(domainLower) ||
          notes.contains(domainLower) ||
          entryUrl.contains(domainLower)) {
        return true;
      }
    }

    if (packageName != null && packageName.isNotEmpty) {
      final packageLower = packageName.toLowerCase();
      // Check both directions: title in package (e.g. "google" in "com.google.android.gm")
      // and package in title/notes (for entries that store the full package name)
      if (title.contains(packageLower) ||
          packageLower.contains(title) ||
          notes.contains(packageLower)) {
        return true;
      }
    }

    return false;
  }).toList();
}

// Global navigator key for autofill navigation
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Hive for local storage
  await Hive.initFlutter();

  final container = ProviderContainer();

  // Load persisted settings (biometric toggle, clipboard timer)
  await loadPersistedSettings(container);
  await DeviceIdentityService(
    keyStorage: container.read(keyStorageProvider),
  ).ensureIdentity();

  final isMobile = !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  // Eagerly initialize IME only on Android where the keyboard integration exists.
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    container.read(imeServiceProvider);
  }

  if (isMobile) {
    // Guard mobile-only services so web startup cannot fail on missing plugins.
    try {
      await BackgroundSyncService.initialize();
    } catch (e) {
      debugPrint('[Startup] Background sync init skipped: $e');
    }

    try {
      await PersistentSshService().initialize();
    } catch (e) {
      debugPrint('[Startup] Persistent SSH init skipped: $e');
    }
  }

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const GitVaultApp(),
    ),
  );
}

class GitVaultApp extends ConsumerWidget {
  const GitVaultApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);

    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'GitVault',
      theme: AppTheme.lightTheme(),
      darkTheme: AppTheme.darkTheme(),
      themeMode: themeMode.toThemeMode(),
      home: const AppShell(),
    );
  }
}

/// Root widget that decides whether to show onboarding or main app
class AppShell extends ConsumerWidget {
  const AppShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isSetup = ref.watch(isVaultSetupProvider);

    return isSetup.when(
      data: (setup) {
        if (setup) {
          return const BiometricGate();
        } else {
          return const OnboardingScreen();
        }
      },
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (err, _) => const BiometricGate(),
    );
  }
}

/// Biometric gate — authenticates user before showing vault
class BiometricGate extends ConsumerStatefulWidget {
  const BiometricGate({super.key});

  @override
  ConsumerState<BiometricGate> createState() => _BiometricGateState();
}

class _BiometricGateState extends ConsumerState<BiometricGate>
    with WidgetsBindingObserver {
  bool _authenticated = false;
  bool _checking = true;
  bool _showPinEntry = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _attemptBiometric();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && _authenticated) {
      // Only lock if biometric or PIN is configured
      final biometricEnabled = ref.read(biometricEnabledProvider);
      _checkAndLock(biometricEnabled);
    } else if (state == AppLifecycleState.resumed && !_authenticated) {
      setState(() => _checking = true);
      _attemptBiometric();
    }
  }

  Future<void> _checkAndLock(bool biometricEnabled) async {
    final pinAuth = ref.read(pinAuthProvider);
    final hasPIN = await pinAuth.isPinSetup();

    if (biometricEnabled || hasPIN) {
      if (mounted) {
        setState(() {
          _authenticated = false;
          _checking = true;
          _showPinEntry = false;
          _error = null;
        });
      }
    }
  }

  void _lockVault() {
    if (!_authenticated || !mounted) return;

    setState(() {
      _authenticated = false;
      _checking = true;
      _showPinEntry = false;
      _error = null;
    });
    unawaited(_attemptBiometric());
  }

  /// Poll native side for pending autofill request (cold-start case).
  /// Called fire-and-forget after every successful auth path.
  Future<void> _pollPendingAutofill() async {
    try {
      final autofillService = ref.read(autofillServiceProvider);
      final pending = await autofillService.getPendingAutofillRequest();
      if (pending == null || !mounted) return;

      // Attempt to auto-select when exactly one credential matches.
      try {
        final vaultRepository = ref.read(vaultRepositoryProvider);
        await vaultRepository.initialize();
        final entries = await vaultRepository.getAllEntries();
        final matches =
            _filterForAutofill(entries, pending['package'], pending['domain']);
        if (matches.length == 1) {
          // Single match — fill directly without showing the picker.
          await autofillService.provideAutofillData(
            username: matches.first.username,
            password: matches.first.password,
          );
          return;
        }
      } catch (_) {
        // If filtering fails, fall through to show picker normally.
      }

      // 0 or multiple matches — show the picker.
      if (mounted) {
        AutofillRequestHandler.instance.setPendingRequest(
          packageName: pending['package'],
          domain: pending['domain'],
        );
        setState(() {}); // trigger rebuild to show AutofillSelectScreen
      }
    } catch (_) {}
  }

  Future<void> _attemptBiometric() async {
    final biometricEnabled = ref.read(biometricEnabledProvider);

    if (!biometricEnabled) {
      // Biometric disabled — check if PIN is set up
      final pinAuth = ref.read(pinAuthProvider);
      final hasPIN = await pinAuth.isPinSetup();
      if (hasPIN) {
        setState(() {
          _showPinEntry = true;
          _checking = false;
        });
        return;
      }
      setState(() {
        _authenticated = true;
        _checking = false;
      });
      _pollPendingAutofill();
      return;
    }

    try {
      final biometricAuth = ref.read(biometricAuthProvider);
      final supported = await biometricAuth.isSupported();

      if (!supported) {
        // Check PIN fallback
        final pinAuth = ref.read(pinAuthProvider);
        final hasPIN = await pinAuth.isPinSetup();
        if (hasPIN) {
          setState(() {
            _showPinEntry = true;
            _checking = false;
          });
          return;
        }
        setState(() {
          _authenticated = true;
          _checking = false;
        });
        _pollPendingAutofill();
        return;
      }

      final enrolled = await biometricAuth.isDeviceEnrolled();
      if (!enrolled) {
        final pinAuth = ref.read(pinAuthProvider);
        final hasPIN = await pinAuth.isPinSetup();
        if (hasPIN) {
          setState(() {
            _showPinEntry = true;
            _checking = false;
          });
          return;
        }
        setState(() {
          _authenticated = true;
          _checking = false;
        });
        _pollPendingAutofill();
        return;
      }

      final result = await biometricAuth.authenticate(
        reason: 'Unlock GitVault',
        biometricOnly: false,
      );

      if (mounted) {
        if (result) {
          setState(() {
            _authenticated = true;
            _checking = false;
          });
          _pollPendingAutofill();
        } else {
          // Biometric failed — offer PIN fallback
          final pinAuth = ref.read(pinAuthProvider);
          final hasPIN = await pinAuth.isPinSetup();
          setState(() {
            _checking = false;
            if (hasPIN) {
              _showPinEntry = true;
            } else {
              _error = 'Authentication failed. Tap "Unlock" to try again.';
            }
          });
        }
      }
    } on BiometricException {
      // Biometric error - try PIN fallback
      if (mounted) {
        final pinAuth = ref.read(pinAuthProvider);
        final hasPIN = await pinAuth.isPinSetup();
        if (hasPIN) {
          setState(() {
            _checking = false;
            _showPinEntry = true;
          });
        } else {
          setState(() {
            _authenticated = true;
            _checking = false;
          });
          _pollPendingAutofill();
        }
      }
    } catch (e) {
      if (mounted) {
        final pinAuth = ref.read(pinAuthProvider);
        final hasPIN = await pinAuth.isPinSetup();
        if (!mounted) return;

        if (hasPIN) {
          setState(() {
            _checking = false;
            _showPinEntry = true;
          });
        } else {
          setState(() {
            _authenticated = true;
            _checking = false;
          });
          _pollPendingAutofill();
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(appLockSignalProvider, (previous, next) {
      if (previous != null && previous != next) {
        _lockVault();
      }
    });

    if (_checking) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_authenticated) {
      // Check for pending autofill request and show autofill screen directly
      final pendingRequest =
          AutofillRequestHandler.instance.consumePendingRequest();
      if (pendingRequest != null) {
        return AutofillSelectScreen(
          packageName: pendingRequest['packageName'],
          domain: pendingRequest['domain'],
        );
      }
      return const MainScreen();
    }

    if (_showPinEntry) {
      return _PinEntryScreen(
        onSuccess: () {
          setState(() {
            _authenticated = true;
            _showPinEntry = false;
          });
          _pollPendingAutofill();
        },
        onRetryBiometric: () {
          setState(() {
            _checking = true;
            _showPinEntry = false;
            _error = null;
          });
          _attemptBiometric();
        },
      );
    }

    // Auth failed — show retry screen
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.lock,
                  size: 64, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 24),
              const Text(
                'GitVault is Locked',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                _error ?? 'Authenticate to continue',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              FilledButton.icon(
                onPressed: () {
                  setState(() {
                    _checking = true;
                    _error = null;
                  });
                  _attemptBiometric();
                },
                icon: const Icon(Icons.fingerprint),
                label: const Text('Unlock'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// PIN entry screen with numeric keypad
class _PinEntryScreen extends ConsumerStatefulWidget {
  final VoidCallback onSuccess;
  final VoidCallback onRetryBiometric;

  const _PinEntryScreen({
    required this.onSuccess,
    required this.onRetryBiometric,
  });

  @override
  ConsumerState<_PinEntryScreen> createState() => _PinEntryScreenState();
}

class _PinEntryScreenState extends ConsumerState<_PinEntryScreen> {
  static const int _minPinLength = 4;
  static const int _maxPinLength = 6;
  static final RegExp _digitPattern = RegExp(r'^\d$');

  late final FocusNode _focusNode;
  late final FocusNode _webPinInputFocus;
  late final TextEditingController _webPinInputController;
  String _pin = '';
  String? _error;
  bool _verifying = false;
  bool _syncingWebPinInput = false;
  Duration _throttleRemaining = Duration.zero;
  Timer? _throttleTimer;
  int? _pinLength;

  bool get _isThrottled => _throttleRemaining > Duration.zero;

  bool get _canSubmitPin =>
      !_verifying &&
      !_isThrottled &&
      _pin.length >= _minPinLength &&
      _pin.length <= _maxPinLength;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    _webPinInputFocus = FocusNode();
    _webPinInputController = TextEditingController();
    _loadPinLength();
    _loadThrottleState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _requestKeyboardFocus();
        if (kIsWeb) {
          Future<void>.delayed(
            const Duration(milliseconds: 150),
            _requestKeyboardFocus,
          );
          Future<void>.delayed(
            const Duration(milliseconds: 500),
            _requestKeyboardFocus,
          );
        }
      }
    });
  }

  @override
  void dispose() {
    _throttleTimer?.cancel();
    _pin = '';
    _clearWebPinInput();
    _webPinInputController.dispose();
    _webPinInputFocus.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _requestKeyboardFocus() {
    if (!mounted) return;
    if (kIsWeb) {
      FocusScope.of(context).requestFocus(_webPinInputFocus);
    } else {
      FocusScope.of(context).requestFocus(_focusNode);
    }
  }

  void _syncWebPinInput() {
    if (!kIsWeb || _webPinInputController.text == _pin) return;
    _syncingWebPinInput = true;
    try {
      _webPinInputController.value = TextEditingValue(
        text: _pin,
        selection: TextSelection.collapsed(offset: _pin.length),
      );
    } finally {
      _syncingWebPinInput = false;
    }
  }

  void _clearWebPinInput() {
    if (!kIsWeb) return;
    _syncingWebPinInput = true;
    try {
      _webPinInputController.clear();
    } finally {
      _syncingWebPinInput = false;
    }
  }

  Future<void> _loadPinLength() async {
    final pinLength = await ref.read(pinAuthProvider).getPinLength();
    if (!mounted) return;

    if (pinLength != null &&
        pinLength >= _minPinLength &&
        pinLength <= _maxPinLength) {
      setState(() => _pinLength = pinLength);
    }
  }

  Future<void> _loadThrottleState() async {
    final remaining = await ref.read(pinAuthProvider).getThrottleDelay();
    if (!mounted) return;
    _applyThrottle(remaining);
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    if (kIsWeb && _webPinInputFocus.hasFocus) return;

    final key = event.logicalKey;
    final digit = _digitForKey(key);
    if (digit != null) {
      _onDigitPressed(digit);
      return;
    }

    if (key == LogicalKeyboardKey.backspace ||
        key == LogicalKeyboardKey.delete) {
      _onBackspace();
      return;
    }

    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _submitPin();
    }
  }

  String? _digitForKey(LogicalKeyboardKey key) {
    for (var i = 0; i <= 9; i++) {
      final digit = i.toString();
      if (key == LogicalKeyboardKey.findKeyByKeyId(0x00000000030 + i) ||
          key == LogicalKeyboardKey.findKeyByKeyId(0x00200000230 + i)) {
        return digit;
      }
    }

    final label = key.keyLabel;
    if (label.length == 1 && _digitPattern.hasMatch(label)) {
      return label;
    }
    return null;
  }

  void _onDigitPressed(String digit) {
    if (_verifying || _isThrottled || _pin.length >= _maxPinLength) return;
    if (!_focusNode.hasFocus && !(_webPinInputFocus.hasFocus && kIsWeb)) {
      _requestKeyboardFocus();
    }

    setState(() {
      _pin += digit;
      _error = null;
    });
    _syncWebPinInput();

    final pinLength = _pinLength;
    if ((pinLength != null && _pin.length == pinLength) ||
        (pinLength == null && _pin.length == _maxPinLength)) {
      _verifyPin(enteredPinOverride: _pin);
    }
  }

  void _onBackspace() {
    if (_pin.isNotEmpty && !_verifying) {
      if (!_focusNode.hasFocus) {
        _requestKeyboardFocus();
      }
      setState(() {
        _pin = _pin.substring(0, _pin.length - 1);
        _error = null;
      });
      _syncWebPinInput();
    }
  }

  void _onWebPinInputChanged(String value) {
    if (!kIsWeb || _syncingWebPinInput || value == _pin) return;
    if (_verifying || _isThrottled) {
      _syncWebPinInput();
      return;
    }

    final digits = value.replaceAll(RegExp(r'\D'), '');
    final nextPin = digits.length > _maxPinLength
        ? digits.substring(0, _maxPinLength)
        : digits;

    setState(() {
      _pin = nextPin;
      if (nextPin.isNotEmpty) {
        _error = null;
      }
    });
    _syncWebPinInput();

    final pinLength = _pinLength;
    if ((pinLength != null && nextPin.length == pinLength) ||
        (pinLength == null && nextPin.length == _maxPinLength)) {
      _verifyPin(enteredPinOverride: nextPin);
    }
  }

  void _submitPin() {
    if (_verifying) return;
    if (_isThrottled) {
      _loadThrottleState();
      return;
    }

    if (_pin.length < _minPinLength) {
      setState(() => _error = 'PIN must be at least 4 digits.');
      return;
    }

    _verifyPin(enteredPinOverride: _pin);
  }

  Future<void> _verifyPin({String? enteredPinOverride}) async {
    if (_verifying) return;
    if (_isThrottled) {
      _loadThrottleState();
      return;
    }

    final enteredPin = enteredPinOverride ?? _pin;
    if (enteredPin.length < _minPinLength ||
        enteredPin.length > _maxPinLength) {
      return;
    }

    final pinAuth = ref.read(pinAuthProvider);
    final throttleDelay = await pinAuth.getThrottleDelay();
    if (!mounted) return;
    if (throttleDelay > Duration.zero) {
      _applyThrottle(throttleDelay);
      return;
    }

    setState(() {
      _verifying = true;
      _error = null;
    });
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;

    final valid = await pinAuth.verifyPin(enteredPin);
    if (!mounted) return;

    if (valid) {
      _pin = '';
      _clearWebPinInput();
      widget.onSuccess();
      return;
    }

    final nextThrottleDelay = await pinAuth.getThrottleDelay();
    if (!mounted) return;

    setState(() {
      _pin = '';
      _error =
          nextThrottleDelay > Duration.zero ? null : 'Wrong PIN. Try again.';
      _verifying = false;
    });
    _syncWebPinInput();

    if (nextThrottleDelay > Duration.zero) {
      _applyThrottle(nextThrottleDelay);
    } else {
      _requestKeyboardFocus();
    }
  }

  void _applyThrottle(Duration remaining) {
    _throttleTimer?.cancel();
    final rounded = _roundThrottle(remaining);

    setState(() {
      _throttleRemaining = rounded;
      if (rounded > Duration.zero) {
        _error = null;
      }
    });

    if (rounded <= Duration.zero) return;

    _throttleTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      final next = _throttleRemaining - const Duration(seconds: 1);
      if (next <= Duration.zero) {
        timer.cancel();
        setState(() => _throttleRemaining = Duration.zero);
        _requestKeyboardFocus();
      } else {
        setState(() => _throttleRemaining = next);
      }
    });
  }

  Duration _roundThrottle(Duration remaining) {
    if (remaining <= Duration.zero) return Duration.zero;
    return Duration(seconds: (remaining.inMilliseconds + 999) ~/ 1000);
  }

  String _formatThrottle(Duration remaining) {
    final totalSeconds = remaining.inSeconds;
    if (totalSeconds < 60) return '${totalSeconds}s';

    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    if (seconds == 0) return '${minutes}m';
    return '${minutes}m ${seconds}s';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final throttleMessage = _isThrottled
        ? 'Too many wrong PIN attempts. Try again in ${_formatThrottle(_throttleRemaining)}.'
        : null;
    final webPinError = kIsWeb ? throttleMessage ?? _error : null;

    return Scaffold(
      body: KeyboardListener(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _handleKeyEvent,
        child: Listener(
          onPointerDown: (_) => _requestKeyboardFocus(),
          child: SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Semantics(
                  container: true,
                  label: 'GitVault is locked. Enter your PIN to unlock.',
                  explicitChildNodes: true,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.lock, size: 48, color: colorScheme.primary),
                      const SizedBox(height: 16),
                      Semantics(
                        header: true,
                        child: Text(
                          'Enter PIN',
                          style: TextStyle(
                              fontSize: 24, fontWeight: FontWeight.bold),
                        ),
                      ),
                      const SizedBox(height: 24),
                      if (kIsWeb)
                        _buildWebPinInput(colorScheme, webPinError)
                      else
                        _buildPinDots(colorScheme),
                      if (!kIsWeb && throttleMessage != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          throttleMessage,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: colorScheme.error,
                            fontSize: 14,
                          ),
                        ),
                      ] else if (!kIsWeb && _error != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          _error!,
                          style: TextStyle(
                            color: colorScheme.error,
                            fontSize: 14,
                          ),
                        ),
                      ] else if (_verifying) ...[
                        const SizedBox(height: 12),
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ],
                      const SizedBox(height: 32),
                      ..._buildKeypad(colorScheme),
                      if (!kIsWeb) ...[
                        const SizedBox(height: 16),
                        TextButton.icon(
                          onPressed: widget.onRetryBiometric,
                          icon: const Icon(Icons.fingerprint),
                          label: const Text('Use Biometrics'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPinDots(ColorScheme colorScheme) {
    return Semantics(
      label:
          'PIN entry, ${_pin.length} of ${_pinLength ?? _maxPinLength} digits entered',
      child: ExcludeSemantics(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(6, (i) {
            final filled = i < _pin.length;
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 8),
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: filled ? colorScheme.primary : Colors.transparent,
                border: Border.all(
                  color: _error != null || _isThrottled
                      ? colorScheme.error
                      : colorScheme.primary,
                  width: 2,
                ),
              ),
            );
          }),
        ),
      ),
    );
  }

  Widget _buildWebPinInput(ColorScheme colorScheme, String? errorText) {
    return Semantics(
      textField: true,
      label: 'GitVault PIN input',
      value: '${_pin.length} of ${_pinLength ?? _maxPinLength} digits entered',
      child: SizedBox(
        width: 220,
        child: PointerFocus(
          focusNode: _webPinInputFocus,
          child: TextField(
            controller: _webPinInputController,
            focusNode: _webPinInputFocus,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            maxLength: _maxPinLength,
            readOnly: _isThrottled,
            textAlign: TextAlign.center,
            enableInteractiveSelection: false,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(_maxPinLength),
            ],
            decoration: InputDecoration(
              labelText: 'GitVault PIN',
              counterText: '',
              errorText: errorText,
              errorMaxLines: 2,
              border: const OutlineInputBorder(),
              enabledBorder: OutlineInputBorder(
                borderSide: BorderSide(color: colorScheme.primary),
              ),
            ),
            style: const TextStyle(
              fontSize: 24,
              letterSpacing: 8,
            ),
            onTap: _requestKeyboardFocus,
            onChanged: _onWebPinInputChanged,
            onSubmitted: (_) => _submitPin(),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildKeypad(ColorScheme colorScheme) {
    const rows = [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
      ['done', '0', 'del'],
    ];

    return rows.map((row) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: row.map((key) {
            if (key == 'done') {
              return SizedBox(
                width: 72,
                height: 56,
                child: Semantics(
                  label: 'Submit PIN',
                  button: true,
                  enabled: _canSubmitPin,
                  child: ExcludeSemantics(
                    child: TextButton(
                      onPressed: _canSubmitPin ? _submitPin : null,
                      child: const Icon(Icons.check),
                    ),
                  ),
                ),
              );
            }
            if (key == 'del') {
              return SizedBox(
                width: 72,
                height: 56,
                child: Semantics(
                  label: 'Delete digit',
                  button: true,
                  enabled: !_verifying && !_isThrottled,
                  child: ExcludeSemantics(
                    child: TextButton(
                      onPressed:
                          (_verifying || _isThrottled) ? null : _onBackspace,
                      child: const Icon(Icons.backspace_outlined),
                    ),
                  ),
                ),
              );
            }
            return Container(
              width: 72,
              height: 56,
              margin: const EdgeInsets.symmetric(horizontal: 8),
              child: Semantics(
                label: 'Digit $key',
                button: true,
                enabled: !_verifying && !_isThrottled,
                child: ExcludeSemantics(
                  child: ElevatedButton(
                    onPressed: (_verifying || _isThrottled)
                        ? null
                        : () => _onDigitPressed(key),
                    style: ElevatedButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: Text(key, style: const TextStyle(fontSize: 24)),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      );
    }).toList();
  }
}

/// Main screen with adaptive navigation for compact and wide layouts.
class MainScreen extends ConsumerStatefulWidget {
  const MainScreen({super.key});

  @override
  ConsumerState<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends ConsumerState<MainScreen> {
  static const double _railBreakpoint = 720;
  static const double _extendedRailBreakpoint = 1100;
  static const double _mobileNavigationBarHeight = 80;
  static const String _uiSettingsBoxName = 'ui_settings';
  static const String _lastTabKey = 'last_tab_index';

  int _currentIndex = 0; // Default to Passwords tab

  static const _destinations = [
    _AppDestination(icon: Icons.password, label: 'Passwords'),
    _AppDestination(icon: Icons.security, label: '2FA Codes'),
    _AppDestination(icon: Icons.note, label: 'Notes'),
    _AppDestination(icon: Icons.terminal, label: 'SSH'),
    _AppDestination(icon: Icons.settings, label: 'Settings'),
  ];

  @override
  void initState() {
    super.initState();
    unawaited(_loadLastTab());
  }

  Future<void> _loadLastTab() async {
    final box = await Hive.openBox<String>(_uiSettingsBoxName);
    final storedIndex = int.tryParse(box.get(_lastTabKey) ?? '');
    if (storedIndex == null ||
        storedIndex < 0 ||
        storedIndex >= _destinations.length ||
        !mounted) {
      return;
    }

    setState(() => _currentIndex = storedIndex);
  }

  void _selectDestination(int index) {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _currentIndex = index);
    unawaited(_saveLastTab(index));
  }

  Future<void> _saveLastTab(int index) async {
    final box = await Hive.openBox<String>(_uiSettingsBoxName);
    await box.put(_lastTabKey, index.toString());
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      const VaultScreen(),
      const TotpCodesPage(),
      const NotesScreen(),
      const SshScreen(),
      SettingsScreen(isActive: _currentIndex == 4),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final useRail = constraints.maxWidth >= _railBreakpoint;

        if (!useRail) {
          return Scaffold(
            body: Padding(
              padding: const EdgeInsets.only(
                bottom: _mobileNavigationBarHeight,
              ),
              child: IndexedStack(
                index: _currentIndex,
                children: screens,
              ),
            ),
            bottomNavigationBar: NavigationBar(
              height: _mobileNavigationBarHeight,
              selectedIndex: _currentIndex,
              onDestinationSelected: _selectDestination,
              destinations: [
                for (final destination in _destinations)
                  NavigationDestination(
                    icon: Icon(destination.icon),
                    label: destination.label,
                  ),
              ],
            ),
          );
        }

        final useExtendedRail = constraints.maxWidth >= _extendedRailBreakpoint;

        return Scaffold(
          body: Row(
            children: [
              SafeArea(
                child: NavigationRail(
                  selectedIndex: _currentIndex,
                  onDestinationSelected: _selectDestination,
                  extended: useExtendedRail,
                  labelType:
                      useExtendedRail ? null : NavigationRailLabelType.all,
                  minExtendedWidth: 200,
                  trailing: kIsWeb
                      ? const Expanded(
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: Padding(
                              padding: EdgeInsets.only(bottom: 16),
                              child: WebLockAction(filled: true),
                            ),
                          ),
                        )
                      : null,
                  destinations: [
                    for (final destination in _destinations)
                      NavigationRailDestination(
                        icon: Icon(destination.icon),
                        label: Text(destination.label),
                      ),
                  ],
                ),
              ),
              const VerticalDivider(width: 1, thickness: 1),
              Expanded(
                child: IndexedStack(
                  index: _currentIndex,
                  children: screens,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _AppDestination {
  final IconData icon;
  final String label;

  const _AppDestination({
    required this.icon,
    required this.label,
  });
}
