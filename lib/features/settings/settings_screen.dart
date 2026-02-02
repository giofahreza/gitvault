import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/auth/biometric_auth.dart';
import '../../core/crypto/crypto_manager.dart';
import '../../core/providers/providers.dart';
import '../../core/services/github_service.dart';
import '../../data/repositories/sync_engine.dart';
import '../../utils/mnemonic_helper.dart';
import '../device_linking/link_device_screen.dart';

/// Settings and security controls screen
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final biometricEnabled = ref.watch(biometricEnabledProvider);
    final clipboardSeconds = ref.watch(clipboardClearSecondsProvider);
    final themeMode = ref.watch(themeModeProvider);
    final autoSyncInterval = ref.watch(autoSyncIntervalProvider);
    final pinEnabledAsync = ref.watch(pinEnabledProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: ListView(
        children: [
          const _SectionHeader(title: 'Appearance'),
          ListTile(
            leading: const Icon(Icons.palette),
            title: const Text('Theme'),
            subtitle: Text(_getThemeLabel(themeMode)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showThemeSelector(context, ref, themeMode),
          ),
          const Divider(),
          const _SectionHeader(title: 'Security'),
          ListTile(
            leading: const Icon(Icons.fingerprint),
            title: const Text('Biometric Authentication'),
            subtitle: Text(biometricEnabled ? 'Enabled' : 'Disabled'),
            trailing: Switch(
              value: biometricEnabled,
              onChanged: (value) => _toggleBiometric(value),
            ),
          ),
          pinEnabledAsync.when(
            data: (pinEnabled) => ListTile(
              leading: const Icon(Icons.pin),
              title: const Text('PIN Lock'),
              subtitle: Text(pinEnabled ? 'Configured' : 'Not set up'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _showPinSettings(context, ref, pinEnabled),
            ),
            loading: () => const ListTile(
              leading: Icon(Icons.pin),
              title: Text('PIN Lock'),
              subtitle: Text('Loading...'),
            ),
            error: (_, __) => const ListTile(
              leading: Icon(Icons.pin),
              title: Text('PIN Lock'),
              subtitle: Text('Error'),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.warning),
            title: const Text('Duress Mode'),
            subtitle: const Text('Configure panic PIN'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showDuressSetup(context, ref),
          ),
          ListTile(
            leading: const Icon(Icons.timer),
            title: const Text('Clipboard Auto-Clear'),
            subtitle: Text('Clear after $clipboardSeconds seconds'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showClipboardSettings(context, ref, clipboardSeconds),
          ),
          ListTile(
            leading: const Icon(Icons.auto_awesome),
            title: const Text('System-wide Autofill'),
            subtitle: const Text('Fill passwords in any app'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showAutofillSettings(context, ref),
          ),
          ListTile(
            leading: const Icon(Icons.keyboard),
            title: const Text('GitVault Keyboard'),
            subtitle: const Text('Custom IME for credential filling'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showKeyboardSettings(context, ref),
          ),
          const Divider(),
          const _SectionHeader(title: 'Devices'),
          ListTile(
            leading: const Icon(Icons.phone_android),
            title: const Text('This Device'),
            subtitle: const Text('Primary'),
          ),
          ListTile(
            leading: const Icon(Icons.add),
            title: const Text('Link New Device'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const LinkDeviceScreen()),
              );
            },
          ),
          const Divider(),
          const _SectionHeader(title: 'Backup'),
          _GitHubStatusTile(),
          ListTile(
            leading: const Icon(Icons.sync),
            title: const Text('Sync Now'),
            subtitle: const Text('Manually sync with GitHub'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _performSync(context, ref),
          ),
          ListTile(
            leading: const Icon(Icons.timer_outlined),
            title: const Text('Auto-Sync'),
            subtitle: Text(_getAutoSyncLabel(autoSyncInterval)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showAutoSyncSettings(context, ref, autoSyncInterval),
          ),
          ListTile(
            leading: const Icon(Icons.download),
            title: const Text('Download Recovery Kit'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showRecoveryKit(context, ref),
          ),
          const Divider(),
          const _SectionHeader(title: 'About'),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('GitVault'),
            subtitle: const Text('Version 1.0.0'),
            trailing: const Icon(Icons.open_in_new, size: 16),
            onTap: () => _launchUrl('https://github.com/giofahreza/gitvault'),
          ),
          ListTile(
            leading: const Icon(Icons.code),
            title: const Text('Developer'),
            subtitle: const Text('Giofahreza'),
            trailing: const Icon(Icons.open_in_new, size: 16),
            onTap: () => _launchUrl('https://giofahreza.com'),
          ),
          ListTile(
            leading: const Icon(Icons.security),
            title: const Text('Encryption'),
            subtitle: const Text('XChaCha20-Poly1305'),
          ),
          ListTile(
            leading: const Icon(Icons.storage),
            title: const Text('Storage'),
            subtitle: const Text('GitHub (End-to-End Encrypted)'),
          ),
          const Divider(),
          const _SectionHeader(title: 'Danger Zone'),
          ListTile(
            leading: const Icon(Icons.delete_forever, color: Colors.red),
            title: const Text('Wipe All Data', style: TextStyle(color: Colors.red)),
            onTap: () => _showWipeConfirmation(context, ref),
          ),
        ],
      ),
    );
  }

  Future<void> _launchUrl(String url) async {
    try {
      final uri = Uri.parse(url);
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open $url: $e')),
        );
      }
    }
  }

  String _getAutoSyncLabel(int minutes) {
    if (minutes <= 0) return 'Off';
    if (minutes == 1) return 'Every minute';
    return 'Every $minutes minutes';
  }

  void _showAutoSyncSettings(BuildContext context, WidgetRef ref, int current) {
    showDialog(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Auto-Sync Interval'),
        children: [
          for (final minutes in [0, 1, 5, 15, 30])
            RadioListTile<int>(
              title: Text(minutes == 0 ? 'Off' : minutes == 1 ? 'Every minute' : 'Every $minutes minutes'),
              value: minutes,
              groupValue: current,
              onChanged: (value) {
                ref.read(autoSyncIntervalProvider.notifier).state = value!;
                ref.read(keyStorageProvider).setAutoSyncInterval(value);
                Navigator.pop(ctx);
              },
            ),
        ],
      ),
    );
  }

  void _showPinSettings(BuildContext context, WidgetRef ref, bool pinEnabled) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('PIN Lock'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!pinEnabled) ...[
              const Text('Set up a 4-6 digit PIN as a backup unlock method.'),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  _showSetupPinDialog(context, ref);
                },
                child: const Text('Set Up PIN'),
              ),
            ] else ...[
              const Text('PIN lock is configured.'),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  _showChangePinDialog(context, ref);
                },
                child: const Text('Change PIN'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                onPressed: () {
                  Navigator.pop(ctx);
                  _removePinDialog(context, ref);
                },
                child: const Text('Remove PIN'),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showSetupPinDialog(BuildContext context, WidgetRef ref) {
    final pinController = TextEditingController();
    final confirmController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Set Up PIN'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: pinController,
              decoration: const InputDecoration(
                labelText: 'Enter PIN (4-6 digits)',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
              maxLength: 6,
              obscureText: true,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: confirmController,
              decoration: const InputDecoration(
                labelText: 'Confirm PIN',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
              maxLength: 6,
              obscureText: true,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final pin = pinController.text;
              final confirm = confirmController.text;

              if (pin.length < 4) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('PIN must be at least 4 digits')),
                );
                return;
              }
              if (pin != confirm) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('PINs do not match')),
                );
                return;
              }

              final pinAuth = ref.read(pinAuthProvider);
              await pinAuth.setupPin(pin);
              ref.invalidate(pinEnabledProvider);

              if (context.mounted) {
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('PIN configured successfully')),
                );
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _showChangePinDialog(BuildContext context, WidgetRef ref) {
    final oldPinController = TextEditingController();
    final newPinController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Change PIN'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: oldPinController,
              decoration: const InputDecoration(
                labelText: 'Current PIN',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
              maxLength: 6,
              obscureText: true,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: newPinController,
              decoration: const InputDecoration(
                labelText: 'New PIN (4-6 digits)',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
              maxLength: 6,
              obscureText: true,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              if (newPinController.text.length < 4) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('New PIN must be at least 4 digits')),
                );
                return;
              }

              final pinAuth = ref.read(pinAuthProvider);
              final changed = await pinAuth.changePin(
                oldPinController.text,
                newPinController.text,
              );

              if (context.mounted) {
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(changed ? 'PIN changed successfully' : 'Current PIN is incorrect'),
                  ),
                );
              }
            },
            child: const Text('Change'),
          ),
        ],
      ),
    );
  }

  void _removePinDialog(BuildContext context, WidgetRef ref) {
    final pinController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove PIN'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Enter your current PIN to remove it.'),
            const SizedBox(height: 16),
            TextField(
              controller: pinController,
              decoration: const InputDecoration(
                labelText: 'Current PIN',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
              maxLength: 6,
              obscureText: true,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              final pinAuth = ref.read(pinAuthProvider);
              final valid = await pinAuth.verifyPin(pinController.text);

              if (valid) {
                await pinAuth.removePin();
                ref.invalidate(pinEnabledProvider);
                if (context.mounted) {
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('PIN removed')),
                  );
                }
              } else {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Incorrect PIN')),
                  );
                }
              }
            },
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleBiometric(bool enable) async {
    if (enable) {
      // Test biometric before enabling
      try {
        final biometricAuth = ref.read(biometricAuthProvider);

        // Check if biometrics are supported
        final supported = await biometricAuth.isSupported();
        if (!supported) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Biometrics not supported on this device')),
            );
          }
          return;
        }

        // Check if biometrics are enrolled
        final enrolled = await biometricAuth.isDeviceEnrolled();
        if (!enrolled) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('No fingerprint or face enrolled. Please set up biometrics in device settings first.')),
            );
          }
          return;
        }

        // Test authentication
        final result = await biometricAuth.authenticate(
          reason: 'Verify biometric authentication',
          biometricOnly: false,
        );

        if (result) {
          // Success! Enable biometrics
          ref.read(biometricEnabledProvider.notifier).state = true;
          await ref.read(keyStorageProvider).setBiometricEnabled(true);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Biometric authentication enabled')),
            );
          }
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Authentication failed or cancelled')),
            );
          }
        }
      } on BiometricException catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Biometric error: ${e.message}')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e')),
          );
        }
      }
    } else {
      // Disable biometrics (no test needed)
      ref.read(biometricEnabledProvider.notifier).state = false;
      await ref.read(keyStorageProvider).setBiometricEnabled(false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Biometric authentication disabled')),
        );
      }
    }
  }

  String _getThemeLabel(AppThemeMode mode) {
    return mode.getLabel();
  }

  void _showThemeSelector(BuildContext context, WidgetRef ref, AppThemeMode current) {
    showDialog(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Choose Theme'),
        children: [
          RadioListTile<AppThemeMode>(
            title: const Text('Light'),
            value: AppThemeMode.light,
            groupValue: current,
            onChanged: (value) {
              ref.read(themeModeProvider.notifier).state = value!;
              ref.read(keyStorageProvider).setThemeMode(value.toStorageString());
              Navigator.pop(ctx);
            },
          ),
          RadioListTile<AppThemeMode>(
            title: const Text('Dark'),
            value: AppThemeMode.dark,
            groupValue: current,
            onChanged: (value) {
              ref.read(themeModeProvider.notifier).state = value!;
              ref.read(keyStorageProvider).setThemeMode(value.toStorageString());
              Navigator.pop(ctx);
            },
          ),
          RadioListTile<AppThemeMode>(
            title: const Text('System'),
            subtitle: const Text('Follow device settings'),
            value: AppThemeMode.system,
            groupValue: current,
            onChanged: (value) {
              ref.read(themeModeProvider.notifier).state = value!;
              ref.read(keyStorageProvider).setThemeMode(value.toStorageString());
              Navigator.pop(ctx);
            },
          ),
        ],
      ),
    );
  }

  void _showDuressSetup(BuildContext context, WidgetRef ref) {
    final pinController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Duress Mode Setup'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Set a panic PIN. Entering this PIN will wipe the vault and show decoy data.'),
            const SizedBox(height: 16),
            TextField(
              controller: pinController,
              decoration: const InputDecoration(
                labelText: 'Panic PIN',
                hintText: '6 digits',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
              maxLength: 6,
              obscureText: true,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              if (pinController.text.length != 6) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('PIN must be 6 digits')),
                );
                return;
              }
              Navigator.pop(ctx);
              try {
                final duressManager = ref.read(duressManagerProvider);
                await duressManager.setupDuressMode(pin: pinController.text);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Duress PIN configured')),
                  );
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Failed: $e')),
                  );
                }
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _showClipboardSettings(BuildContext context, WidgetRef ref, int current) {
    showDialog(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Clipboard Auto-Clear'),
        children: [
          for (final seconds in [10, 30, 60, 120])
            RadioListTile<int>(
              title: Text('$seconds seconds'),
              value: seconds,
              groupValue: current,
              onChanged: (value) {
                ref.read(clipboardClearSecondsProvider.notifier).state = value!;
                ref.read(keyStorageProvider).setClipboardClearSeconds(value);
                Navigator.pop(ctx);
              },
            ),
        ],
      ),
    );
  }

  void _showKeyboardSettings(BuildContext context, WidgetRef ref) async {
    final imeService = ref.read(imeServiceProvider);
    final isEnabled = await imeService.isIMEEnabled();

    if (!context.mounted) return;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('GitVault Keyboard'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isEnabled
                  ? 'GitVault keyboard is enabled. Switch to it when filling credentials.'
                  : 'Enable GitVault as a keyboard input method to fill credentials without switching apps.',
            ),
            const SizedBox(height: 16),
            if (!isEnabled)
              const Text(
                'You will be taken to keyboard settings.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                if (!isEnabled) {
                  await imeService.openIMESettings();
                } else {
                  await imeService.showKeyboardPicker();
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Error: $e')),
                  );
                }
              }
            },
            child: Text(isEnabled ? 'Switch Keyboard' : 'Enable'),
          ),
        ],
      ),
    );
  }

  void _showAutofillSettings(BuildContext context, WidgetRef ref) async {
    final autofillService = ref.read(autofillServiceProvider);
    final isEnabled = await autofillService.isAutofillServiceEnabled();

    if (!context.mounted) return;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('System-wide Autofill'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isEnabled
                  ? 'GitVault autofill is enabled. Passwords will be suggested in other apps and websites.'
                  : 'Enable GitVault as your autofill service to fill passwords in any app or website.',
            ),
            const SizedBox(height: 16),
            if (!isEnabled)
              const Text(
                'You will be taken to system settings to enable autofill.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          if (!isEnabled)
            FilledButton(
              onPressed: () async {
                Navigator.pop(ctx);
                try {
                  await autofillService.enableAutofillService();
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Failed to enable autofill: $e')),
                    );
                  }
                }
              },
              child: const Text('Enable'),
            ),
        ],
      ),
    );
  }

  void _showWipeConfirmation(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Wipe All Data'),
        content: const Text(
          'This will permanently delete all vault entries and reset the app. This action CANNOT be undone.\n\nAre you absolutely sure?',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                final repo = ref.read(vaultRepositoryProvider);
                await repo.initialize();
                await repo.clearAllEntries();
                final keyStorage = ref.read(keyStorageProvider);
                await keyStorage.wipeAllKeys();
                ref.invalidate(isVaultSetupProvider);
                ref.invalidate(vaultEntriesProvider);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('All data wiped')),
                  );
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Wipe failed: $e')),
                  );
                }
              }
            },
            child: const Text('Wipe Everything'),
          ),
        ],
      ),
    );
  }

  Future<void> _showRecoveryKit(BuildContext context, WidgetRef ref) async {
    try {
      final keyStorage = ref.read(keyStorageProvider);
      await keyStorage.initialize();

      // Get the current root key
      final rootKey = await keyStorage.getRootKey();
      if (rootKey == null) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No encryption key found. Please complete onboarding first.')),
          );
        }
        return;
      }

      // Convert root key to mnemonic
      final mnemonic = MnemonicHelper.rootKeyToMnemonic(rootKey);
      final formattedMnemonic = MnemonicHelper.formatMnemonicForDisplay(mnemonic);

      if (context.mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Your Recovery Phrase'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'IMPORTANT: Write down these 24 words in order and store them safely.',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.orange),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'If you lose all your devices, this is your only way to recover your data.',
                    style: TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.grey.shade300),
                    ),
                    child: SelectableText(
                      formattedMnemonic,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Close'),
              ),
              FilledButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: mnemonic));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Recovery phrase copied to clipboard')),
                  );
                },
                icon: const Icon(Icons.copy),
                label: const Text('Copy'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to retrieve recovery phrase: $e')),
        );
      }
    }
  }

  Future<void> _performSync(BuildContext context, WidgetRef ref) async {
    final keyStorage = ref.read(keyStorageProvider);
    await keyStorage.initialize();
    final hasGitHub = await keyStorage.hasGitHubCredentials();

    if (!hasGitHub) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('GitHub not configured. Set it up first.')),
        );
      }
      return;
    }

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Checking sync status...')),
      );
    }

    GitHubService? githubService;

    try {
      final token = await keyStorage.getGitHubToken();
      final owner = await keyStorage.getRepoOwner();
      final name = await keyStorage.getRepoName();

      if (token == null || owner == null || name == null) {
        throw Exception('GitHub credentials incomplete');
      }

      githubService = GitHubService(
        accessToken: token,
        repoOwner: owner,
        repoName: name,
      );

      // Check if repo has existing vault data
      final indexBytes = await githubService.downloadFile('vault_index.enc');
      final hasExistingData = indexBytes != null;

      // Check if local vault is empty (check all repositories)
      final vaultRepo = ref.read(vaultRepositoryProvider);
      await vaultRepo.initialize();
      final localEntries = await vaultRepo.getAllEntries();

      final notesRepo = ref.read(notesRepositoryProvider);
      await notesRepo.initialize();
      final localNotes = await notesRepo.getAllNotes();

      final sshRepo = ref.read(sshRepositoryProvider);
      await sshRepo.initialize();
      final localSsh = await sshRepo.getAllCredentials();

      final hasLocalData = localEntries.isNotEmpty || localNotes.isNotEmpty || localSsh.isNotEmpty;

      // If repo has data but local is empty, prompt for recovery or wipe
      if (hasExistingData && !hasLocalData) {
        githubService.dispose();

        if (context.mounted) {
          // Remove "checking" message
          ScaffoldMessenger.of(context).hideCurrentSnackBar();

          _showRecoveryCodeDialog(
            context,
            ref,
            token: token,
            owner: owner,
            repo: name,
          );
        }
        return;
      }

      // Proceed with normal sync
      final syncEngine = SyncEngine(
        vaultRepository: ref.read(vaultRepositoryProvider),
        notesRepository: ref.read(notesRepositoryProvider),
        sshRepository: ref.read(sshRepositoryProvider),
        githubService: githubService,
        cryptoManager: ref.read(cryptoManagerProvider),
        keyStorage: keyStorage,
      );

      await syncEngine.initialize();
      final result = await syncEngine.sync();
      syncEngine.dispose(); // Don't close the box, just dispose resources
      githubService.dispose();

      // Invalidate all data providers to reload synced data
      ref.invalidate(vaultEntriesProvider);
      ref.invalidate(notesProvider);
      ref.invalidate(sshCredentialsProvider);

      if (context.mounted) {
        String message;
        if (result.pushed == 0 && result.pulled == 0) {
          message = 'Synced (up to date)';
        } else {
          message = 'Synced: ${result.pushed} pushed, ${result.pulled} pulled';
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      githubService?.dispose();

      final errorMsg = e.toString().toLowerCase();

      // Check if it's a decryption/MAC error (wrong encryption key)
      if (errorMsg.contains('mac') || errorMsg.contains('decrypt')) {
        if (context.mounted) {
          // Directly show the recovery phrase input dialog (no intermediate dialog)
          final token = await keyStorage.getGitHubToken();
          final owner = await keyStorage.getRepoOwner();
          final repoName = await keyStorage.getRepoName();
          if (token != null && owner != null && repoName != null) {
            _showEnterRecoveryCodeDialog(
              context,
              ref,
              token: token,
              owner: owner,
              repo: repoName,
            );
          }
        }
      } else {
        // Other sync errors
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Sync failed: $e')),
          );
        }
      }
    }
  }
}

/// Shows real GitHub connection status with ability to configure
class _GitHubStatusTile extends ConsumerStatefulWidget {
  @override
  ConsumerState<_GitHubStatusTile> createState() => _GitHubStatusTileState();
}

class _GitHubStatusTileState extends ConsumerState<_GitHubStatusTile> {
  bool _connected = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _checkConnection();
  }

  Future<void> _checkConnection() async {
    final keyStorage = ref.read(keyStorageProvider);
    await keyStorage.initialize();
    final hasCredentials = await keyStorage.hasGitHubCredentials();
    if (mounted) {
      setState(() {
        _connected = hasCredentials;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const ListTile(
        leading: Icon(Icons.cloud, color: Colors.grey),
        title: Text('GitHub Sync'),
        subtitle: Text('Checking...'),
        trailing: Icon(Icons.chevron_right),
      );
    }

    return ListTile(
      leading: Icon(
        Icons.cloud,
        color: _connected ? Colors.green : Colors.grey,
      ),
      title: const Text('GitHub Sync'),
      subtitle: Text(_connected ? 'Connected' : 'Not configured'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _showGitHubSettings(context, ref, _connected),
    );
  }

  void _showGitHubSettings(BuildContext context, WidgetRef ref, bool connected) async {
    final keyStorage = ref.read(keyStorageProvider);
    await keyStorage.initialize();

    if (connected) {
      // Show current configuration
      final owner = await keyStorage.getRepoOwner();
      final repo = await keyStorage.getRepoName();

      if (!context.mounted) return;

      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('GitHub Sync'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.check_circle, color: Colors.green, size: 20),
                  SizedBox(width: 8),
                  Text('Connected', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.green)),
                ],
              ),
              const SizedBox(height: 16),
              Text('Owner: ${owner ?? 'Unknown'}'),
              const SizedBox(height: 4),
              Text('Repository: ${repo ?? 'Unknown'}'),
              const SizedBox(height: 16),
              const Text(
                'Encrypted vault data is automatically synced to your private GitHub repository.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _showGitHubSetupDialog(context, ref, isEditing: true);
              },
              child: const Text('Edit'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } else {
      // Show setup dialog
      _showGitHubSetupDialog(context, ref, isEditing: false);
    }
  }

  void _showGitHubSetupDialog(BuildContext context, WidgetRef ref, {required bool isEditing}) {
    final repoOwnerController = TextEditingController();
    final repoNameController = TextEditingController();
    final tokenController = TextEditingController();
    bool validating = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(isEditing ? 'Edit GitHub Sync' : 'Setup GitHub Sync'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isEditing
                      ? 'Update your GitHub repository credentials.'
                      : 'Connect your private GitHub repository to sync your vault.',
                  style: const TextStyle(fontSize: 14),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: repoOwnerController,
                  decoration: const InputDecoration(
                    labelText: 'GitHub Username',
                    hintText: 'giofahreza',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.person),
                  ),
                  enabled: !validating,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: repoNameController,
                  decoration: const InputDecoration(
                    labelText: 'Repository Name',
                    hintText: 'my-vault',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.folder),
                  ),
                  enabled: !validating,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: tokenController,
                  decoration: const InputDecoration(
                    labelText: 'Personal Access Token',
                    hintText: 'ghp_...',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.key),
                  ),
                  obscureText: true,
                  enabled: !validating,
                ),
                const SizedBox(height: 8),
                Text(
                  'Generate at: github.com/settings/tokens',
                  style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: validating ? null : () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: validating
                  ? null
                  : () async {
                      final owner = repoOwnerController.text.trim();
                      final repo = repoNameController.text.trim();
                      final token = tokenController.text.trim();

                      if (owner.isEmpty || repo.isEmpty || token.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Please fill in all fields')),
                        );
                        return;
                      }

                      // Validate credentials
                      setState(() => validating = true);

                      try {
                        final github = GitHubService(
                          accessToken: token,
                          repoOwner: owner,
                          repoName: repo,
                        );

                        await github.verifyRepository();

                        // Check if repo has existing vault data
                        final indexBytes = await github.downloadFile('vault_index.enc');
                        final hasExistingData = indexBytes != null;

                        // Check if local vault is empty
                        final vaultRepo = ref.read(vaultRepositoryProvider);
                        await vaultRepo.initialize();
                        final localEntries = await vaultRepo.getAllEntries();
                        final hasLocalData = localEntries.isNotEmpty;

                        github.dispose();

                        // If repo has data but local is empty, prompt for recovery or wipe
                        if (hasExistingData && !hasLocalData) {
                          setState(() => validating = false);
                          Navigator.pop(ctx);

                          if (context.mounted) {
                            _showRecoveryCodeDialog(
                              context,
                              ref,
                              token: token,
                              owner: owner,
                              repo: repo,
                            );
                          }
                          return;
                        }

                        // Save credentials
                        final keyStorage = ref.read(keyStorageProvider);
                        await keyStorage.initialize();
                        await keyStorage.storeGitHubCredentials(
                          token: token,
                          repoOwner: owner,
                          repoName: repo,
                        );

                        // Refresh connection status
                        await _checkConnection();

                        if (context.mounted) {
                          Navigator.pop(ctx);
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('GitHub sync configured successfully'),
                              backgroundColor: Colors.green,
                            ),
                          );
                        }
                      } catch (e) {
                        setState(() => validating = false);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Validation failed: $e')),
                          );
                        }
                      }
                    },
              child: validating
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('Save & Validate'),
            ),
          ],
        ),
      ),
    );
  }
}

// Standalone recovery dialog functions
void _showRecoveryCodeDialog(
  BuildContext context,
  WidgetRef ref, {
  required String token,
  required String owner,
  required String repo,
}) {
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: const Text('Existing Vault Found'),
      content: const Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'This repository already contains encrypted vault data.',
            style: TextStyle(fontSize: 14),
          ),
          SizedBox(height: 16),
          Text(
            'Choose how to proceed:',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
          ),
          SizedBox(height: 12),
          Text(
            'Restore with your 24-word recovery phrase',
            style: TextStyle(fontSize: 13),
          ),
          SizedBox(height: 4),
          Text(
            'Or erase the repo and start fresh',
            style: TextStyle(fontSize: 13),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.pop(ctx);
            _showEnterRecoveryCodeDialog(context, ref, token: token, owner: owner, repo: repo);
          },
          child: const Text('Restore with Recovery Phrase'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.orange),
          onPressed: () {
            Navigator.pop(ctx);
            _showEraseRepoDialog(context, ref, token: token, owner: owner, repo: repo);
          },
          child: const Text('Erase & Start Fresh'),
        ),
      ],
    ),
  );
}

void _showEnterRecoveryCodeDialog(
  BuildContext context,
  WidgetRef ref, {
  required String token,
  required String owner,
  required String repo,
}) {
  final recoveryCodeController = TextEditingController();
  bool validating = false;

  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Enter 24-Word Recovery Phrase'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Enter your 24-word recovery phrase to decrypt the existing vault.',
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 12),
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.amber.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.amber.shade200),
              ),
              child: Row(
                children: [
                  Icon(Icons.help_outline, size: 20, color: Colors.amber.shade900),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'This is the 24-word phrase from your original device, NOT your GitHub password or token.',
                      style: TextStyle(fontSize: 11, color: Colors.amber.shade900),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: recoveryCodeController,
              decoration: const InputDecoration(
                labelText: '24-Word Recovery Phrase',
                hintText: 'word1 word2 word3 ...',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
              enabled: !validating,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: validating ? null : () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: validating
                ? null
                : () async {
                    final recoveryCode = recoveryCodeController.text.trim();
                    if (recoveryCode.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Please enter recovery phrase')),
                      );
                      return;
                    }

                    setState(() => validating = true);

                    try {
                      // Normalize and validate mnemonic
                      final mnemonic = MnemonicHelper.normalizeMnemonic(recoveryCode);

                      if (!MnemonicHelper.isValidMnemonic(mnemonic)) {
                        throw Exception('Invalid recovery phrase. Please check your words and try again.');
                      }

                      // Derive root key from mnemonic
                      final rootKey = MnemonicHelper.mnemonicToRootKey(mnemonic);

                      // Store the key and credentials - we'll verify during actual sync
                      final keyStorage = ref.read(keyStorageProvider);
                      await keyStorage.initialize();
                      await keyStorage.storeRootKey(rootKey);

                      // Key already stored by sync test above
                      // Just store GitHub credentials
                      await keyStorage.storeGitHubCredentials(
                        token: token,
                        repoOwner: owner,
                        repoName: repo,
                      );

                      if (context.mounted) {
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Recovery phrase saved. Click "Sync Now" to restore vault data.'),
                            backgroundColor: Colors.green,
                          ),
                        );

                        // Trigger sync to download vault data
                        ref.invalidate(isVaultSetupProvider);
                      }
                    } catch (e) {
                      setState(() => validating = false);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Failed: $e')),
                        );
                      }
                    }
                  },
            child: validating
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Text('Restore'),
          ),
        ],
      ),
    ),
  );
}

void _showEraseRepoDialog(
  BuildContext context,
  WidgetRef ref, {
  required String token,
  required String owner,
  required String repo,
}) {
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Erase Repository Data?'),
      content: const Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'WARNING: This will permanently delete all existing vault data in the repository.',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.red),
          ),
          SizedBox(height: 16),
          Text(
            'This action cannot be undone. Only proceed if you are sure you want to start fresh.',
            style: TextStyle(fontSize: 14),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.red),
          onPressed: () async {
            try {
              final github = GitHubService(
                accessToken: token,
                repoOwner: owner,
                repoName: repo,
              );

              // Delete all data files in the data/ folder
              try {
                final dataFiles = await github.listFiles('data');
                for (final fileName in dataFiles) {
                  try {
                    await github.deleteFile(
                      path: 'data/$fileName',
                      commitMessage: 'Clear vault data',
                    );
                  } catch (_) {}
                }
              } catch (_) {}

              // Delete index file
              try {
                await github.deleteFile(
                  path: 'index.bin',
                  commitMessage: 'Clear vault index',
                );
              } catch (_) {}

              // Also try to delete old format files if they exist
              try {
                await github.deleteFile(
                  path: 'vault_index.enc',
                  commitMessage: 'Clear old vault',
                );
              } catch (_) {}

              github.dispose();

              // Save credentials
              final keyStorage = ref.read(keyStorageProvider);
              await keyStorage.initialize();
              await keyStorage.storeGitHubCredentials(
                token: token,
                repoOwner: owner,
                repoName: repo,
              );

              if (context.mounted) {
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Repository erased successfully. GitHub sync configured.'),
                    backgroundColor: Colors.green,
                  ),
                );
              }
            } catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Failed to erase: $e')),
                );
              }
            }
          },
          child: const Text('Erase & Continue'),
        ),
      ],
    ),
  );
}

class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.bold,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}
