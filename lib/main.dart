import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'core/auth/biometric_auth.dart';
import 'core/providers/providers.dart';
import 'core/services/autofill_request_handler.dart';
import 'core/services/github_service.dart';
import 'core/theme/app_theme.dart';
import 'data/repositories/sync_engine.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/vault/vault_screen.dart';
import 'features/totp/totp_codes_page.dart';
import 'features/notes/notes_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/autofill/autofill_select_screen.dart';

// Global navigator key for autofill navigation
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Hive for local storage
  await Hive.initFlutter();

  final container = ProviderContainer();

  // Load persisted settings (biometric toggle, clipboard timer)
  await loadPersistedSettings(container);

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

class _BiometricGateState extends ConsumerState<BiometricGate> {
  bool _authenticated = false;
  bool _checking = true;
  bool _showPinEntry = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _attemptBiometric();
  }

  Future<void> _attemptBiometric() async {
    final biometricEnabled = ref.read(biometricEnabledProvider);
    if (!biometricEnabled) {
      // Biometric disabled — check if PIN is set up
      final pinAuth = ref.read(pinAuthProvider);
      final hasPIN = await pinAuth.isPinSetup();
      if (hasPIN) {
        setState(() { _showPinEntry = true; _checking = false; });
        return;
      }
      setState(() { _authenticated = true; _checking = false; });
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
          setState(() { _showPinEntry = true; _checking = false; });
          return;
        }
        setState(() { _authenticated = true; _checking = false; });
        return;
      }

      final enrolled = await biometricAuth.isDeviceEnrolled();
      if (!enrolled) {
        final pinAuth = ref.read(pinAuthProvider);
        final hasPIN = await pinAuth.isPinSetup();
        if (hasPIN) {
          setState(() { _showPinEntry = true; _checking = false; });
          return;
        }
        setState(() { _authenticated = true; _checking = false; });
        return;
      }

      final result = await biometricAuth.authenticate(
        reason: 'Unlock GitVault',
        biometricOnly: false,
      );

      if (mounted) {
        if (result) {
          setState(() { _authenticated = true; _checking = false; });
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
        setState(() {
          _checking = false;
          if (hasPIN) {
            _showPinEntry = true;
          } else {
            _authenticated = true;
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _authenticated = true;
          _checking = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_authenticated) {
      // Check for pending autofill request and show autofill screen directly
      final pendingRequest = AutofillRequestHandler.instance.consumePendingRequest();
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
          setState(() { _authenticated = true; _showPinEntry = false; });
        },
        onRetryBiometric: () {
          setState(() { _checking = true; _showPinEntry = false; _error = null; });
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
              Icon(Icons.lock, size: 64, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 24),
              const Text(
                'GitVault is Locked',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                _error ?? 'Authenticate to continue',
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              FilledButton.icon(
                onPressed: () {
                  setState(() { _checking = true; _error = null; });
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
  String _pin = '';
  String? _error;
  bool _verifying = false;

  Future<void> _onDigitPressed(String digit) async {
    if (_verifying || _pin.length >= 6) return;

    setState(() {
      _pin += digit;
      _error = null;
    });

    // Auto-verify when 4-6 digits entered (try at 4, 5, 6)
    if (_pin.length >= 4) {
      setState(() => _verifying = true);
      final pinAuth = ref.read(pinAuthProvider);
      final valid = await pinAuth.verifyPin(_pin);
      if (valid) {
        widget.onSuccess();
      } else if (_pin.length >= 6) {
        setState(() {
          _pin = '';
          _error = 'Wrong PIN. Try again.';
          _verifying = false;
        });
      } else {
        setState(() => _verifying = false);
      }
    }
  }

  void _onBackspace() {
    if (_pin.isNotEmpty && !_verifying) {
      setState(() {
        _pin = _pin.substring(0, _pin.length - 1);
        _error = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.lock, size: 48, color: colorScheme.primary),
                const SizedBox(height: 16),
                const Text(
                  'Enter PIN',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 24),
                // PIN dots
                Row(
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
                          color: _error != null ? colorScheme.error : colorScheme.primary,
                          width: 2,
                        ),
                      ),
                    );
                  }),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: TextStyle(color: colorScheme.error, fontSize: 14)),
                ],
                const SizedBox(height: 32),
                // Numeric keypad
                ..._buildKeypad(colorScheme),
                const SizedBox(height: 16),
                TextButton.icon(
                  onPressed: widget.onRetryBiometric,
                  icon: const Icon(Icons.fingerprint),
                  label: const Text('Use Biometrics'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildKeypad(ColorScheme colorScheme) {
    final rows = [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
      ['', '0', 'del'],
    ];

    return rows.map((row) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: row.map((key) {
            if (key.isEmpty) {
              return const SizedBox(width: 72, height: 56);
            }
            if (key == 'del') {
              return SizedBox(
                width: 72,
                height: 56,
                child: TextButton(
                  onPressed: _onBackspace,
                  child: const Icon(Icons.backspace_outlined),
                ),
              );
            }
            return Container(
              width: 72,
              height: 56,
              margin: const EdgeInsets.symmetric(horizontal: 8),
              child: ElevatedButton(
                onPressed: () => _onDigitPressed(key),
                style: ElevatedButton.styleFrom(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: Text(key, style: const TextStyle(fontSize: 24)),
              ),
            );
          }).toList(),
        ),
      );
    }).toList();
  }
}

/// Main screen with bottom navigation between Vault and Settings
class MainScreen extends ConsumerStatefulWidget {
  const MainScreen({super.key});

  @override
  ConsumerState<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends ConsumerState<MainScreen> {
  int _currentIndex = 0;
  Timer? _autoSyncTimer;
  bool _isSyncing = false;

  final _screens = const [
    VaultScreen(),
    TotpCodesPage(),
    NotesScreen(),
    SettingsScreen(),
  ];

  @override
  void initState() {
    super.initState();
    _setupAutoSync();
  }

  @override
  void dispose() {
    _autoSyncTimer?.cancel();
    super.dispose();
  }

  void _setupAutoSync() {
    _autoSyncTimer?.cancel();
    final interval = ref.read(autoSyncIntervalProvider);
    if (interval > 0) {
      _autoSyncTimer = Timer.periodic(Duration(minutes: interval), (_) {
        _performAutoSync();
      });
    }
  }

  Future<void> _performAutoSync() async {
    if (_isSyncing) return;

    try {
      final keyStorage = ref.read(keyStorageProvider);
      await keyStorage.initialize();
      final hasGitHub = await keyStorage.hasGitHubCredentials();
      if (!hasGitHub) return;

      setState(() => _isSyncing = true);

      final token = await keyStorage.getGitHubToken();
      final owner = await keyStorage.getRepoOwner();
      final name = await keyStorage.getRepoName();

      if (token == null || owner == null || name == null) return;

      final githubService = GitHubService(
        accessToken: token,
        repoOwner: owner,
        repoName: name,
      );

      final syncEngine = SyncEngine(
        vaultRepository: ref.read(vaultRepositoryProvider),
        notesRepository: ref.read(notesRepositoryProvider),
        githubService: githubService,
        cryptoManager: ref.read(cryptoManagerProvider),
        keyStorage: keyStorage,
      );

      await syncEngine.initialize();
      await syncEngine.sync();
      await syncEngine.close();
      githubService.dispose();

      ref.invalidate(vaultEntriesProvider);
      ref.invalidate(notesProvider);
    } catch (_) {
      // Silent failure for auto-sync
    } finally {
      if (mounted) {
        setState(() => _isSyncing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Listen for auto-sync interval changes
    ref.listen<int>(autoSyncIntervalProvider, (prev, next) {
      _setupAutoSync();
    });

    return Scaffold(
      body: Stack(
        children: [
          IndexedStack(
            index: _currentIndex,
            children: _screens,
          ),
          if (_isSyncing)
            Positioned(
              top: MediaQuery.of(context).padding.top + 4,
              right: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Syncing...',
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) {
          setState(() => _currentIndex = index);
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.password),
            label: 'Passwords',
          ),
          NavigationDestination(
            icon: Icon(Icons.security),
            label: '2FA Codes',
          ),
          NavigationDestination(
            icon: Icon(Icons.note),
            label: 'Notes',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
