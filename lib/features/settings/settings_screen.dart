import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/auth/biometric_auth.dart';
import '../../core/providers/providers.dart';
import '../../core/services/device_identity_service.dart';
import '../../core/services/github_service.dart';
import '../../core/services/ime_service.dart';
import '../../core/services/foreground_sync_service.dart';
import '../../core/widgets/web_lock_action.dart';
import '../../data/repositories/sync_engine.dart';
import '../../utils/constants.dart';
import '../../utils/auth_helper.dart';
import '../../utils/mnemonic_helper.dart';
import '../../utils/pointer_focus.dart';
import '../device_linking/link_device_screen.dart';
import 'background_sync_settings.dart';

/// Settings and security controls screen
class SettingsScreen extends ConsumerStatefulWidget {
  final bool isActive;

  const SettingsScreen({
    super.key,
    this.isActive = true,
  });

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late final Future<String> _appVersionFuture;
  late final ScrollController _settingsScrollController;
  late final FocusNode _settingsFocusNode;
  bool _duressConfigured = false;
  bool _duressStatusLoading = true;

  @override
  void initState() {
    super.initState();
    _appVersionFuture = _loadAppVersion();
    _settingsScrollController = ScrollController();
    _settingsFocusNode = FocusNode(debugLabel: 'SettingsScrollFocus');
    _loadDuressStatus();
    if (widget.isActive) _requestSettingsFocus();
  }

  @override
  void didUpdateWidget(covariant SettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      _requestSettingsFocus();
    }
  }

  @override
  void dispose() {
    _settingsScrollController.dispose();
    _settingsFocusNode.dispose();
    super.dispose();
  }

  bool get _showPersistentScrollbar =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;

  void _requestSettingsFocus() {
    void request() {
      if (!mounted || !widget.isActive) return;
      final route = ModalRoute.of(context);
      if (route != null && !route.isCurrent) return;
      _settingsFocusNode.requestFocus();
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      request();
      Future<void>.delayed(const Duration(milliseconds: 80), request);
      Future<void>.delayed(const Duration(milliseconds: 220), request);
    });
  }

  KeyEventResult _handleSettingsKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || !_settingsScrollController.hasClients) {
      return KeyEventResult.ignored;
    }

    final position = _settingsScrollController.position;
    final key = event.logicalKey;
    final pageStep = position.viewportDimension * 0.85;
    final lineStep = 64.0;
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

    if (target == null) return KeyEventResult.ignored;

    final clamped = target
        .clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        )
        .toDouble();
    _settingsScrollController.animateTo(
      clamped,
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
    );
    return KeyEventResult.handled;
  }

  Future<String> _loadAppVersion() async {
    const releaseVersion = String.fromEnvironment('GITVAULT_VERSION');
    if (releaseVersion.isNotEmpty) return releaseVersion;

    final packageInfo = await PackageInfo.fromPlatform();
    return packageInfo.version.isEmpty ? 'Unknown' : packageInfo.version;
  }

  Future<void> _loadDuressStatus() async {
    try {
      final configured =
          await ref.read(duressManagerProvider).isDuressConfigured();
      if (mounted) {
        setState(() {
          _duressConfigured = configured;
          _duressStatusLoading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _duressStatusLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final biometricEnabled = ref.watch(biometricEnabledProvider);
    final clipboardSeconds = ref.watch(clipboardClearSecondsProvider);
    final themeMode = ref.watch(themeModeProvider);
    final pinEnabledAsync = ref.watch(pinEnabledProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: const [
          WebLockAction(compactOnly: true),
        ],
      ),
      body: Focus(
        focusNode: _settingsFocusNode,
        autofocus: true,
        onKeyEvent: _handleSettingsKey,
        child: Scrollbar(
          controller: _settingsScrollController,
          thumbVisibility: _showPersistentScrollbar,
          interactive: true,
          child: ListView(
            controller: _settingsScrollController,
            primary: false,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: EdgeInsets.only(
              bottom: 96 + MediaQuery.paddingOf(context).bottom,
            ),
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
              if (kIsWeb)
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Text(
                    'Web biometric unlock uses your browser passkey or platform authenticator. Autofill and GitVault Keyboard are available in the Android app.',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              Semantics(
                container: true,
                label: 'Biometric Authentication',
                value: biometricEnabled ? 'Enabled' : 'Disabled',
                button: true,
                toggled: biometricEnabled,
                child: ListTile(
                  leading: const Icon(Icons.fingerprint),
                  title: const Text('Biometric Authentication'),
                  subtitle: Text(
                    biometricEnabled
                        ? 'Enabled'
                        : kIsWeb
                            ? 'Use browser biometric unlock'
                            : 'Disabled',
                  ),
                  trailing: Switch(
                    value: biometricEnabled,
                    onChanged: (value) => _toggleBiometric(value),
                  ),
                  onTap: () => _toggleBiometric(!biometricEnabled),
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
                subtitle: Text(
                  _duressStatusLoading
                      ? 'Checking...'
                      : _duressConfigured
                          ? 'Panic PIN configured'
                          : 'Not configured',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _showDuressSetup(context, ref),
              ),
              ListTile(
                leading: const Icon(Icons.timer),
                title: const Text('Clipboard Auto-Clear'),
                subtitle: Text('Clear after $clipboardSeconds seconds'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () =>
                    _showClipboardSettings(context, ref, clipboardSeconds),
              ),
              if (kIsWeb) ...[
                const _WebOnlySettingsTile(
                  icon: Icons.auto_awesome,
                  title: 'System-wide Autofill',
                  subtitle: 'Available in the Android app',
                ),
                const _WebOnlySettingsTile(
                  icon: Icons.keyboard,
                  title: 'GitVault Keyboard',
                  subtitle: 'Available in the Android app',
                ),
              ] else ...[
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
              ],
              const Divider(),
              const _SectionHeader(title: 'Devices'),
              _DeviceListSection(isActive: widget.isActive),
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
              _BackgroundSyncStatusTile(),
              ListTile(
                leading: const Icon(Icons.download),
                title: const Text('View Recovery Phrase'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _showRecoveryKit(context, ref),
              ),
              const Divider(),
              const _SectionHeader(title: 'About'),
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('GitVault'),
                subtitle: FutureBuilder<String>(
                  future: _appVersionFuture,
                  builder: (context, snapshot) {
                    final version = snapshot.data ?? '...';
                    return Text('Version $version');
                  },
                ),
                trailing: const Icon(Icons.open_in_new, size: 16),
                onTap: () =>
                    _launchUrl('https://github.com/giofahreza/gitvault'),
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
                title: const Text('Wipe All Data',
                    style: TextStyle(color: Colors.red)),
                onTap: () => _showWipeConfirmation(context, ref),
              ),
            ],
          ),
        ),
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

  Future<void> _showSetupPinDialog(BuildContext context, WidgetRef ref) async {
    final pinController = TextEditingController();
    final confirmController = TextEditingController();
    final pinFocus = FocusNode();
    final confirmFocus = FocusNode();
    var saving = false;
    String? error;

    Future<void> savePin(
      BuildContext dialogContext,
      StateSetter setDialogState,
    ) async {
      if (saving) return;

      final pin = pinController.text;
      final confirm = confirmController.text;

      if (pin.length < 4) {
        setDialogState(() => error = 'PIN must be at least 4 digits');
        return;
      }
      if (pin.length > 6) {
        setDialogState(() => error = 'PIN must be 6 digits or fewer');
        return;
      }
      if (pin != confirm) {
        setDialogState(() => error = 'PINs do not match');
        return;
      }

      setDialogState(() {
        saving = true;
        error = null;
      });

      try {
        final pinAuth = ref.read(pinAuthProvider);
        await pinAuth.setupPin(pin);
        ref.invalidate(pinEnabledProvider);

        if (!dialogContext.mounted) return;
        Navigator.of(dialogContext).pop();
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('PIN configured successfully')),
          );
        }
      } catch (e) {
        if (dialogContext.mounted) {
          setDialogState(() {
            saving = false;
            error = 'Failed to save PIN: $e';
          });
        }
      }
    }

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Set Up PIN'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              PointerFocus(
                focusNode: pinFocus,
                child: TextField(
                  controller: pinController,
                  focusNode: pinFocus,
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
                  enabled: !saving,
                  textInputAction: TextInputAction.next,
                  onSubmitted: (_) => confirmFocus.requestFocus(),
                ),
              ),
              const SizedBox(height: 12),
              PointerFocus(
                focusNode: confirmFocus,
                child: TextField(
                  controller: confirmController,
                  focusNode: confirmFocus,
                  decoration: const InputDecoration(
                    labelText: 'Confirm PIN',
                    border: OutlineInputBorder(),
                    counterText: '',
                  ),
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  maxLength: 6,
                  obscureText: true,
                  enabled: !saving,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => savePin(dialogContext, setDialogState),
                ),
              ),
              if (error != null) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed:
                  saving ? null : () => savePin(dialogContext, setDialogState),
              child: saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save'),
            ),
          ],
        ),
      ),
    );

    pinController.clear();
    confirmController.clear();
    pinController.dispose();
    confirmController.dispose();
    pinFocus.dispose();
    confirmFocus.dispose();
  }

  Future<void> _showChangePinDialog(BuildContext context, WidgetRef ref) async {
    final oldPinController = TextEditingController();
    final newPinController = TextEditingController();
    final oldPinFocus = FocusNode();
    final newPinFocus = FocusNode();
    var saving = false;
    String? error;

    Future<void> changePin(
      BuildContext dialogContext,
      StateSetter setDialogState,
    ) async {
      if (saving) return;

      if (oldPinController.text.length < 4) {
        setDialogState(() => error = 'Current PIN must be at least 4 digits');
        return;
      }
      if (newPinController.text.length < 4) {
        setDialogState(() => error = 'New PIN must be at least 4 digits');
        return;
      }

      setDialogState(() {
        saving = true;
        error = null;
      });

      try {
        final pinAuth = ref.read(pinAuthProvider);
        final changed = await pinAuth.changePin(
          oldPinController.text,
          newPinController.text,
        );

        if (!dialogContext.mounted) return;
        if (!changed) {
          setDialogState(() {
            saving = false;
            error = 'Current PIN is incorrect';
          });
          return;
        }

        ref.invalidate(pinEnabledProvider);
        Navigator.of(dialogContext).pop();
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('PIN changed successfully')),
          );
        }
      } catch (e) {
        if (dialogContext.mounted) {
          setDialogState(() {
            saving = false;
            error = 'Failed to change PIN: $e';
          });
        }
      }
    }

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Change PIN'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              PointerFocus(
                focusNode: oldPinFocus,
                child: TextField(
                  controller: oldPinController,
                  focusNode: oldPinFocus,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Current PIN',
                    border: OutlineInputBorder(),
                    counterText: '',
                  ),
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  maxLength: 6,
                  obscureText: true,
                  enabled: !saving,
                  textInputAction: TextInputAction.next,
                  onSubmitted: (_) => newPinFocus.requestFocus(),
                ),
              ),
              const SizedBox(height: 12),
              PointerFocus(
                focusNode: newPinFocus,
                child: TextField(
                  controller: newPinController,
                  focusNode: newPinFocus,
                  decoration: const InputDecoration(
                    labelText: 'New PIN (4-6 digits)',
                    border: OutlineInputBorder(),
                    counterText: '',
                  ),
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  maxLength: 6,
                  obscureText: true,
                  enabled: !saving,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => changePin(dialogContext, setDialogState),
                ),
              ),
              if (error != null) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: saving
                  ? null
                  : () => changePin(dialogContext, setDialogState),
              child: saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Change'),
            ),
          ],
        ),
      ),
    );

    oldPinController.clear();
    newPinController.clear();
    oldPinController.dispose();
    newPinController.dispose();
    oldPinFocus.dispose();
    newPinFocus.dispose();
  }

  Future<void> _removePinDialog(BuildContext context, WidgetRef ref) async {
    final pinController = TextEditingController();
    final pinFocus = FocusNode();
    var removing = false;
    String? error;

    Future<void> removePin(
      BuildContext dialogContext,
      StateSetter setDialogState,
    ) async {
      if (removing) return;

      if (pinController.text.length < 4) {
        setDialogState(() => error = 'Enter your current PIN');
        return;
      }

      setDialogState(() {
        removing = true;
        error = null;
      });

      try {
        final pinAuth = ref.read(pinAuthProvider);
        final valid = await pinAuth.verifyPin(pinController.text);

        if (!dialogContext.mounted) return;
        if (!valid) {
          setDialogState(() {
            removing = false;
            error = 'Incorrect PIN';
            pinController.clear();
          });
          return;
        }

        await pinAuth.removePin();
        ref.invalidate(pinEnabledProvider);
        Navigator.of(dialogContext).pop();
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('PIN removed')),
          );
        }
      } catch (e) {
        if (dialogContext.mounted) {
          setDialogState(() {
            removing = false;
            error = 'Failed to remove PIN: $e';
          });
        }
      }
    }

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Remove PIN'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Enter your current PIN to remove it.'),
              const SizedBox(height: 16),
              PointerFocus(
                focusNode: pinFocus,
                child: TextField(
                  controller: pinController,
                  focusNode: pinFocus,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Current PIN',
                    border: OutlineInputBorder(),
                    counterText: '',
                  ),
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  maxLength: 6,
                  obscureText: true,
                  enabled: !removing,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => removePin(dialogContext, setDialogState),
                ),
              ),
              if (error != null) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: removing ? null : () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: removing
                  ? null
                  : () => removePin(dialogContext, setDialogState),
              child: removing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Remove'),
            ),
          ],
        ),
      ),
    );

    pinController.clear();
    pinController.dispose();
    pinFocus.dispose();
  }

  Future<void> _toggleBiometric(bool enable) async {
    if (enable) {
      try {
        final biometricAuth = ref.read(biometricAuthProvider);
        final supported = await biometricAuth.isSupported();
        if (!supported) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  kIsWeb
                      ? 'Browser biometric unlock is not available in this browser or origin'
                      : 'Biometrics not supported on this device',
                ),
              ),
            );
          }
          return;
        }

        final result = await biometricAuth.setup(
          reason: 'Verify biometric authentication',
        );

        if (result) {
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
              const SnackBar(
                  content: Text('Authentication failed or cancelled')),
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
      final keyStorage = ref.read(keyStorageProvider);
      ref.read(biometricEnabledProvider.notifier).state = false;
      await keyStorage.setBiometricEnabled(false);
      if (kIsWeb) {
        await keyStorage.clearWebBiometricCredential();
      }
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

  void _showThemeSelector(
      BuildContext context, WidgetRef ref, AppThemeMode current) {
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
              ref
                  .read(keyStorageProvider)
                  .setThemeMode(value.toStorageString());
              IMEService.setThemeMode(value.toStorageString());
              Navigator.pop(ctx);
            },
          ),
          RadioListTile<AppThemeMode>(
            title: const Text('Dark'),
            value: AppThemeMode.dark,
            groupValue: current,
            onChanged: (value) {
              ref.read(themeModeProvider.notifier).state = value!;
              ref
                  .read(keyStorageProvider)
                  .setThemeMode(value.toStorageString());
              IMEService.setThemeMode(value.toStorageString());
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
              ref
                  .read(keyStorageProvider)
                  .setThemeMode(value.toStorageString());
              IMEService.setThemeMode(value.toStorageString());
              Navigator.pop(ctx);
            },
          ),
        ],
      ),
    );
  }

  Future<void> _showDuressSetup(BuildContext context, WidgetRef ref) async {
    final pinController = TextEditingController();
    final pinFocus = FocusNode();
    var saving = false;
    String? error;

    Future<void> saveDuressPin(
      BuildContext dialogContext,
      StateSetter setDialogState,
    ) async {
      if (saving) return;

      final pin = pinController.text;
      if (pin.length != 6) {
        setDialogState(() => error = 'Panic PIN must be exactly 6 digits');
        return;
      }

      setDialogState(() {
        saving = true;
        error = null;
      });

      try {
        final duressManager = ref.read(duressManagerProvider);
        await duressManager.setupDuressMode(pin: pin);
        pinController.clear();

        if (!dialogContext.mounted) return;
        Navigator.pop(dialogContext);
        if (context.mounted) {
          setState(() {
            _duressConfigured = true;
            _duressStatusLoading = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Duress PIN configured')),
          );
        }
      } catch (e) {
        if (dialogContext.mounted) {
          setDialogState(() {
            saving = false;
            error = 'Failed to save duress PIN: $e';
          });
        }
      }
    }

    await showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          title: const Text('Duress Mode Setup'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                    'Set a panic PIN. Entering this PIN will wipe the vault and show decoy data.'),
                const SizedBox(height: 16),
                PointerFocus(
                  focusNode: pinFocus,
                  child: TextField(
                    controller: pinController,
                    focusNode: pinFocus,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: 'Panic PIN',
                      hintText: '6 digits',
                      border: const OutlineInputBorder(),
                      counterText: '',
                      errorText: error,
                    ),
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    maxLength: 6,
                    obscureText: true,
                    enabled: !saving,
                    textInputAction: TextInputAction.done,
                    onChanged: (_) {
                      if (error != null) setDialogState(() => error = null);
                    },
                    onSubmitted: (_) =>
                        saveDuressPin(dialogContext, setDialogState),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: saving
                  ? null
                  : () => saveDuressPin(dialogContext, setDialogState),
              child: saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save'),
            ),
          ],
        ),
      ),
    );

    pinController.clear();
    pinController.dispose();
    pinFocus.dispose();
  }

  void _showClipboardSettings(
      BuildContext context, WidgetRef ref, int current) {
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

  void _showWebUnavailableDialog(
    BuildContext context, {
    required String title,
    required String message,
  }) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        title: Text(title),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Text(message),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showKeyboardSettings(BuildContext context, WidgetRef ref) async {
    if (kIsWeb) {
      _showWebUnavailableDialog(
        context,
        title: 'GitVault Keyboard',
        message:
            'The GitVault keyboard is available in the Android app. Browser keyboards cannot be changed from the web app.',
      );
      return;
    }

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
              Text(
                'You will be taken to keyboard settings.',
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
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
    if (kIsWeb) {
      _showWebUnavailableDialog(
        context,
        title: 'System-wide Autofill',
        message:
            'System-wide autofill is available in the Android app. Browser autofill settings are controlled by your browser.',
      );
      return;
    }

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
              Text(
                'You will be taken to system settings to enable autofill.',
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
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
    final confirmController = TextEditingController();
    final confirmFocus = FocusNode();
    var confirmText = '';

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Wipe All Data'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'This will permanently delete all vault entries and reset the app. This action CANNOT be undone.',
              ),
              const SizedBox(height: 16),
              const Text('Type WIPE to confirm.'),
              const SizedBox(height: 8),
              PointerFocus(
                focusNode: confirmFocus,
                child: TextField(
                  controller: confirmController,
                  focusNode: confirmFocus,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Confirmation',
                    border: OutlineInputBorder(),
                  ),
                  textInputAction: TextInputAction.done,
                  onChanged: (value) {
                    setDialogState(() => confirmText = value.trim());
                  },
                  onSubmitted: (_) {
                    if (confirmText == 'WIPE') {
                      _wipeAllData(context, dialogContext, ref);
                    }
                  },
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: confirmText == 'WIPE'
                  ? () => _wipeAllData(context, dialogContext, ref)
                  : null,
              child: const Text('Wipe Everything'),
            ),
          ],
        ),
      ),
    ).whenComplete(() {
      confirmController.dispose();
      confirmFocus.dispose();
    });
  }

  Future<void> _wipeAllData(
    BuildContext context,
    BuildContext dialogContext,
    WidgetRef ref,
  ) async {
    Navigator.pop(dialogContext);
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
  }

  Future<void> _showRecoveryKit(BuildContext context, WidgetRef ref) async {
    try {
      final authenticated = await AuthHelper.authenticate(
        context: context,
        ref: ref,
        reason: 'Authenticate to view recovery phrase',
      );
      if (!authenticated || !context.mounted) return;

      final keyStorage = ref.read(keyStorageProvider);
      await keyStorage.initialize();

      // Get the current root key
      final rootKey = await keyStorage.getRootKey();
      if (rootKey == null) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text(
                    'No encryption key found. Please complete onboarding first.')),
          );
        }
        return;
      }

      // Convert root key to mnemonic
      final mnemonic = MnemonicHelper.rootKeyToMnemonic(rootKey);
      final formattedMnemonic =
          MnemonicHelper.formatMnemonicForDisplay(mnemonic);

      if (context.mounted) {
        var recoveryCopied = false;
        Timer? recoveryCopyTimer;

        await showDialog(
          context: context,
          builder: (ctx) => StatefulBuilder(
            builder: (dialogContext, setDialogState) => AlertDialog(
              title: const Text('Your Recovery Phrase'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'IMPORTANT: Write down these 24 words in order and store them safely.',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: Colors.orange),
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
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: Theme.of(context).colorScheme.outline),
                      ),
                      child: Semantics(
                        container: true,
                        label:
                            'Your 24-word recovery phrase: $formattedMnemonic',
                        child: ExcludeSemantics(
                          child: SelectableText(
                            formattedMnemonic,
                            style: const TextStyle(
                                fontFamily: 'monospace', fontSize: 11),
                          ),
                        ),
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
                    recoveryCopyTimer?.cancel();
                    setDialogState(() => recoveryCopied = true);
                    ScaffoldMessenger.of(context)
                      ..hideCurrentSnackBar()
                      ..showSnackBar(
                        const SnackBar(
                          content: Text('Recovery phrase copied to clipboard'),
                          duration: Duration(seconds: 2),
                          behavior: SnackBarBehavior.floating,
                          margin: EdgeInsets.fromLTRB(16, 0, 16, 88),
                        ),
                      );
                    recoveryCopyTimer = Timer(const Duration(seconds: 2), () {
                      if (dialogContext.mounted) {
                        setDialogState(() => recoveryCopied = false);
                      }
                    });
                  },
                  icon: Icon(recoveryCopied ? Icons.check : Icons.copy),
                  label: Text(recoveryCopied ? 'Copied' : 'Copy'),
                ),
              ],
            ),
          ),
        ).whenComplete(() => recoveryCopyTimer?.cancel());
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to retrieve recovery phrase: $e')),
        );
      }
    }
  }
}

class _BackgroundSyncStatusTile extends ConsumerStatefulWidget {
  @override
  ConsumerState<_BackgroundSyncStatusTile> createState() =>
      _BackgroundSyncStatusTileState();
}

class _BackgroundSyncStatusTileState
    extends ConsumerState<_BackgroundSyncStatusTile> {
  bool _hasGitHubCredentials = false;
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
        _hasGitHubCredentials = hasCredentials;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(
        Icons.cloud_sync,
        color: _hasGitHubCredentials
            ? null
            : Theme.of(context).colorScheme.outline,
      ),
      title: const Text('Background Sync'),
      subtitle: Text(
        _loading
            ? 'Checking...'
            : _hasGitHubCredentials
                ? 'Battery-optimized background sync'
                : 'Set up GitHub Sync first',
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        final result = await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const BackgroundSyncSettings()),
        );
        if (result == BackgroundSyncSettingsResult.setupGitHub &&
            context.mounted) {
          showGitHubSetupDialog(
            context,
            ref,
            isEditing: false,
            onConfigured: _checkConnection,
          );
        }
        if (mounted) {
          await _checkConnection();
        }
      },
    );
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
      return ListTile(
        leading:
            Icon(Icons.cloud, color: Theme.of(context).colorScheme.outline),
        title: const Text('GitHub Sync'),
        subtitle: const Text('Checking...'),
        trailing: const Icon(Icons.chevron_right),
      );
    }

    return ListTile(
      leading: Icon(
        Icons.cloud,
        color:
            _connected ? Colors.green : Theme.of(context).colorScheme.outline,
      ),
      title: const Text('GitHub Sync'),
      subtitle: Text(_connected ? 'Connected' : 'Not configured'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _showGitHubSettings(context, ref, _connected),
    );
  }

  void _showGitHubSettings(
      BuildContext context, WidgetRef ref, bool connected) async {
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
                  Text('Connected',
                      style: TextStyle(
                          fontWeight: FontWeight.bold, color: Colors.green)),
                ],
              ),
              const SizedBox(height: 16),
              Text('Owner: ${owner ?? 'Unknown'}'),
              const SizedBox(height: 4),
              Text('Repository: ${repo ?? 'Unknown'}'),
              const SizedBox(height: 16),
              Text(
                'Encrypted vault data is automatically synced to your private GitHub repository.',
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                showGitHubSetupDialog(
                  context,
                  ref,
                  isEditing: true,
                  onConfigured: _checkConnection,
                );
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
      showGitHubSetupDialog(
        context,
        ref,
        isEditing: false,
        onConfigured: _checkConnection,
      );
    }
  }
}

Future<void> _openExternalUrl(BuildContext context, String url) async {
  try {
    final uri = Uri.parse(url);
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open $url: $e')),
      );
    }
  }
}

class _GitHubSetupInfoPanel extends StatelessWidget {
  final bool isEditing;

  const _GitHubSetupInfoPanel({required this.isEditing});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.lock_outline,
                  size: 18, color: colorScheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Text(
                isEditing ? 'Storage stays encrypted' : 'What you need',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (!isEditing) ...[
            const _GitHubSetupStep(
              number: '1',
              text:
                  'Create an empty private repository in your GitHub account.',
            ),
            const SizedBox(height: 8),
            const _GitHubSetupStep(
              number: '2',
              text:
                  'Create a token for that repository with Contents read/write access.',
            ),
            const SizedBox(height: 8),
            const _GitHubSetupStep(
              number: '3',
              text: 'Paste the username, repository name, and token here.',
            ),
            const SizedBox(height: 10),
          ],
          Text(
            'GitHub stores only encrypted vault files. It never receives your recovery phrase, PIN, or readable passwords.',
            style: TextStyle(
              fontSize: 12,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _GitHubSetupStep extends StatelessWidget {
  final String number;
  final String text;

  const _GitHubSetupStep({
    required this.number,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: colorScheme.primaryContainer,
            shape: BoxShape.circle,
          ),
          child: Text(
            number,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: colorScheme.onPrimaryContainer,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 12,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

String _formatGitHubSetupError(Object error) {
  final raw = error is GitHubException ? error.message : error.toString();
  final message =
      raw.replaceFirst(RegExp(r'^(Exception|GitHubException):\s*'), '').trim();
  final lower = message.toLowerCase();

  if (lower.contains('bad credentials') ||
      lower.contains('invalid token') ||
      lower.contains('401')) {
    return 'GitHub did not accept this token. Create a new token and paste it again.';
  }

  if (lower.contains('not found') || lower.contains('404')) {
    return 'GitVault could not find that repository. Check the username, repository name, and that the token can access this repo.';
  }

  if (lower.contains('permission') ||
      lower.contains('forbidden') ||
      lower.contains('403')) {
    return 'The token does not have enough access. Give it Contents read/write access for this private repository.';
  }

  if (lower.contains('network') ||
      lower.contains('socket') ||
      lower.contains('timeout')) {
    return 'Could not reach GitHub. Check your internet connection and try again.';
  }

  return 'Could not verify GitHub Sync. Check the username, repository name, token access, then try again.';
}

Future<void> showGitHubSetupDialog(
  BuildContext context,
  WidgetRef ref, {
  required bool isEditing,
  Future<void> Function()? onConfigured,
}) async {
  final repoOwnerController = TextEditingController();
  final repoNameController = TextEditingController();
  final tokenController = TextEditingController();
  final repoOwnerFocus = FocusNode();
  final repoNameFocus = FocusNode();
  final tokenFocus = FocusNode();
  bool validating = false;
  String? validationError;

  await showDialog(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => StatefulBuilder(
      builder: (dialogContext, setState) => AlertDialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        title: Text(isEditing ? 'Edit GitHub Sync' : 'Connect GitHub Sync'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isEditing
                      ? 'Update the private GitHub repository used for encrypted backup storage.'
                      : 'Use a normal personal GitHub account as encrypted backup storage. GitVault encrypts the vault before anything leaves this device.',
                  style: const TextStyle(fontSize: 14),
                ),
                const SizedBox(height: 16),
                _GitHubSetupInfoPanel(isEditing: isEditing),
                const SizedBox(height: 16),
                PointerFocus(
                  focusNode: repoOwnerFocus,
                  child: TextField(
                    controller: repoOwnerController,
                    focusNode: repoOwnerFocus,
                    decoration: const InputDecoration(
                      labelText: 'GitHub username',
                      hintText: 'your-github-username',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.person),
                    ),
                    textInputAction: TextInputAction.next,
                    enabled: !validating,
                    onSubmitted: (_) => repoNameFocus.requestFocus(),
                  ),
                ),
                const SizedBox(height: 12),
                PointerFocus(
                  focusNode: repoNameFocus,
                  child: TextField(
                    controller: repoNameController,
                    focusNode: repoNameFocus,
                    decoration: const InputDecoration(
                      labelText: 'Repository name',
                      hintText: 'gitvault-backup',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.folder),
                    ),
                    textInputAction: TextInputAction.next,
                    enabled: !validating,
                    onSubmitted: (_) => tokenFocus.requestFocus(),
                  ),
                ),
                const SizedBox(height: 12),
                PointerFocus(
                  focusNode: tokenFocus,
                  child: TextField(
                    controller: tokenController,
                    focusNode: tokenFocus,
                    decoration: const InputDecoration(
                      labelText: 'Access token',
                      hintText: 'Paste token from GitHub',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.key),
                    ),
                    obscureText: true,
                    textInputAction: TextInputAction.done,
                    enabled: !validating,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Use a token for this private repository with Contents read/write access. The token is stored only on this device.',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: validating
                        ? null
                        : () => _openExternalUrl(
                              dialogContext,
                              'https://github.com/settings/tokens',
                            ),
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const Text('Open token page'),
                  ),
                ),
                if (validationError != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    validationError!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ],
              ],
            ),
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
                      setState(
                          () => validationError = 'Please fill in all fields');
                      return;
                    }

                    // Validate credentials
                    setState(() {
                      validating = true;
                      validationError = null;
                    });

                    try {
                      final github = GitHubService(
                        accessToken: token,
                        repoOwner: owner,
                        repoName: repo,
                      );

                      await github.verifyRepository();

                      // Check if repo has existing vault data
                      final indexBytes =
                          await github.downloadFile(Constants.indexFile);
                      final hasExistingData = indexBytes != null;

                      github.dispose();

                      final keyStorage = ref.read(keyStorageProvider);
                      await keyStorage.initialize();
                      final hasRootKey = await keyStorage.hasRootKey();

                      // If repo has existing data and device has NO root key yet,
                      // must ask for recovery phrase.
                      if (hasExistingData && !hasRootKey) {
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
                      await keyStorage.storeGitHubCredentials(
                        token: token,
                        repoOwner: owner,
                        repoName: repo,
                      );
                      unawaited(ForegroundSyncService.refreshPeriodicSync());

                      if (context.mounted) {
                        Navigator.pop(ctx);

                        if (hasExistingData && hasRootKey) {
                          // Device already has a root key (e.g. set up as new) —
                          // auto-sync to pull vault data from GitHub using that key.
                          ScaffoldMessenger.of(context).hideCurrentSnackBar();
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Row(
                                children: [
                                  SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2, color: Colors.white)),
                                  SizedBox(width: 12),
                                  Text('Syncing vault from GitHub...'),
                                ],
                              ),
                              duration: Duration(minutes: 2),
                            ),
                          );

                          try {
                            final result = await ForegroundSyncService.syncNow(
                              reason: 'GitHub sync configured',
                            );
                            if (result == null) {
                              throw ForegroundSyncService.lastError ??
                                  Exception('GitHub sync is not configured.');
                            }
                            if (context.mounted) {
                              ref.invalidate(vaultRepositoryProvider);
                              ref.invalidate(vaultEntriesProvider);
                              ref.invalidate(notesRepositoryProvider);
                              ref.invalidate(notesProvider);
                              ref.invalidate(sshRepositoryProvider);
                              ref.invalidate(sshCredentialsProvider);
                              ref.invalidate(archivedNotesProvider);

                              ScaffoldMessenger.of(context)
                                  .hideCurrentSnackBar();
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'GitHub sync configured! Pulled ${result.pulled} item${result.pulled == 1 ? "" : "s"} from vault.',
                                  ),
                                  backgroundColor: Colors.green,
                                  duration: const Duration(seconds: 5),
                                ),
                              );
                            }
                          } catch (syncError) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context)
                                  .hideCurrentSnackBar();
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                      'GitHub configured, but sync failed: $syncError'),
                                  backgroundColor: Colors.orange,
                                  duration: const Duration(seconds: 6),
                                ),
                              );
                            }
                          }
                        } else {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content:
                                  Text('GitHub sync configured successfully'),
                              backgroundColor: Colors.green,
                            ),
                          );
                        }
                      }

                      await onConfigured?.call();
                    } catch (e) {
                      setState(() {
                        validating = false;
                        validationError = _formatGitHubSetupError(e);
                      });
                    }
                  },
            child: validating
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : const Text('Save & Validate'),
          ),
        ],
      ),
    ),
  );

  repoOwnerController.clear();
  repoNameController.clear();
  tokenController.clear();
  repoOwnerController.dispose();
  repoNameController.dispose();
  tokenController.dispose();
  repoOwnerFocus.dispose();
  repoNameFocus.dispose();
  tokenFocus.dispose();
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
            _showEnterRecoveryCodeDialog(context, ref,
                token: token, owner: owner, repo: repo);
          },
          child: const Text('Restore with Recovery Phrase'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.orange),
          onPressed: () {
            Navigator.pop(ctx);
            _showEraseRepoDialog(context, ref,
                token: token, owner: owner, repo: repo);
          },
          child: const Text('Erase & Start Fresh'),
        ),
      ],
    ),
  );
}

Future<void> _showEnterRecoveryCodeDialog(
  BuildContext context,
  WidgetRef ref, {
  required String token,
  required String owner,
  required String repo,
}) async {
  final recoveryCodeController = TextEditingController();
  final recoveryCodeFocus = FocusNode();
  bool validating = false;
  String? validationError;

  await showDialog(
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
            Builder(
              builder: (context) {
                final colorScheme = Theme.of(context).colorScheme;
                return Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: colorScheme.tertiaryContainer,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: colorScheme.tertiary),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.help_outline,
                          size: 20, color: colorScheme.onTertiaryContainer),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'This is the 24-word phrase from your original device, NOT your GitHub password or token.',
                          style: TextStyle(
                              fontSize: 11,
                              color: colorScheme.onTertiaryContainer),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: 16),
            PointerFocus(
              focusNode: recoveryCodeFocus,
              child: TextField(
                controller: recoveryCodeController,
                focusNode: recoveryCodeFocus,
                decoration: const InputDecoration(
                  labelText: '24-Word Recovery Phrase',
                  hintText: 'word1 word2 word3 ...',
                  border: OutlineInputBorder(),
                ),
                maxLines: 3,
                enabled: !validating,
              ),
            ),
            if (validationError != null) ...[
              const SizedBox(height: 12),
              Text(
                validationError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
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
                      setState(() =>
                          validationError = 'Please enter recovery phrase');
                      return;
                    }

                    setState(() {
                      validating = true;
                      validationError = null;
                    });

                    try {
                      // Normalize and validate mnemonic
                      final mnemonic =
                          MnemonicHelper.normalizeMnemonic(recoveryCode);

                      if (!MnemonicHelper.isValidMnemonic(mnemonic)) {
                        throw Exception(
                            'Invalid recovery phrase. Please check your words and try again.');
                      }

                      // Derive root key from mnemonic
                      final rootKey =
                          MnemonicHelper.mnemonicToRootKey(mnemonic);

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
                      unawaited(ForegroundSyncService.refreshPeriodicSync());

                      if (context.mounted) {
                        Navigator.pop(ctx);

                        // Refresh vault setup state so home screen unlocks
                        ref.invalidate(isVaultSetupProvider);

                        // Show syncing progress snackbar
                        ScaffoldMessenger.of(context).hideCurrentSnackBar();
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Row(
                              children: [
                                SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: Colors.white)),
                                SizedBox(width: 12),
                                Text('Syncing vault from GitHub...'),
                              ],
                            ),
                            duration: Duration(minutes: 2),
                          ),
                        );

                        try {
                          final result = await ForegroundSyncService.syncNow(
                            reason: 'recovery phrase restored',
                          );
                          if (result == null) {
                            throw ForegroundSyncService.lastError ??
                                Exception('GitHub sync is not configured.');
                          }

                          if (context.mounted) {
                            ref.invalidate(vaultRepositoryProvider);
                            ref.invalidate(vaultEntriesProvider);
                            ref.invalidate(notesRepositoryProvider);
                            ref.invalidate(notesProvider);
                            ref.invalidate(sshRepositoryProvider);
                            ref.invalidate(sshCredentialsProvider);
                            ref.invalidate(archivedNotesProvider);

                            ScaffoldMessenger.of(context).hideCurrentSnackBar();
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  'Vault restored! Pulled ${result.pulled} item${result.pulled == 1 ? "" : "s"} from GitHub.',
                                ),
                                backgroundColor: Colors.green,
                                duration: const Duration(seconds: 5),
                              ),
                            );
                          }
                        } catch (syncError) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).hideCurrentSnackBar();
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  'Recovery phrase saved, but sync failed: $syncError\n'
                                  'Try "Sync Now" in Settings → Background Sync.',
                                ),
                                backgroundColor: Colors.orange,
                                duration: const Duration(seconds: 6),
                              ),
                            );
                          }
                        }
                      }
                    } catch (e) {
                      setState(() {
                        validating = false;
                        validationError = 'Failed: $e';
                      });
                    }
                  },
            child: validating
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : const Text('Restore'),
          ),
        ],
      ),
    ),
  );

  recoveryCodeController.clear();
  recoveryCodeController.dispose();
  recoveryCodeFocus.dispose();
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
            style: TextStyle(
                fontSize: 14, fontWeight: FontWeight.bold, color: Colors.red),
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
              unawaited(ForegroundSyncService.refreshPeriodicSync());

              if (context.mounted) {
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                        'Repository erased successfully. GitHub sync configured.'),
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

class _DeviceListSection extends ConsumerStatefulWidget {
  final bool isActive;

  const _DeviceListSection({
    required this.isActive,
  });

  @override
  ConsumerState<_DeviceListSection> createState() => _DeviceListSectionState();
}

class _DeviceListSectionState extends ConsumerState<_DeviceListSection> {
  List<Map<String, dynamic>> _devices = [];
  String? _localDeviceId;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadDevices();
  }

  @override
  void didUpdateWidget(covariant _DeviceListSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      _loadDevices();
    }
  }

  Future<void> _loadDevices({bool uploadCurrent = false}) async {
    final keyStorage = ref.read(keyStorageProvider);
    await keyStorage.initialize();
    final identity =
        await DeviceIdentityService(keyStorage: keyStorage).ensureIdentity();

    List<Map<String, dynamic>> devices = [];

    try {
      final token = await keyStorage.getGitHubToken();
      final owner = await keyStorage.getRepoOwner();
      final repo = await keyStorage.getRepoName();

      if (token != null && owner != null && repo != null) {
        final githubService = GitHubService(
          accessToken: token,
          repoOwner: owner,
          repoName: repo,
        );
        try {
          final registry = await SyncEngine.refreshDeviceRegistry(
            keyStorage: keyStorage,
            cryptoManager: ref.read(cryptoManagerProvider),
            githubService: githubService,
            uploadIfNeeded: uploadCurrent,
          );
          final deviceList = registry?['devices'] as List<dynamic>? ?? [];
          devices = deviceList
              .map((d) => Map<String, dynamic>.from(d as Map))
              .toList();
        } finally {
          githubService.dispose();
        }
      }
    } catch (_) {}

    if (devices.isEmpty) {
      final registryJson = await keyStorage.getDeviceRegistry();
      if (registryJson != null) {
        try {
          final registry = jsonDecode(registryJson) as Map<String, dynamic>;
          final deviceList = registry['devices'] as List<dynamic>? ?? [];
          devices = deviceList
              .map((d) => Map<String, dynamic>.from(d as Map))
              .toList();
        } catch (_) {}
      }
    }

    if (devices.isEmpty) {
      devices = [
        {
          'deviceId': identity.id,
          'name': identity.name,
          'lastSeen': DateTime.now().toIso8601String(),
        }
      ];
    } else {
      final localIndex =
          devices.indexWhere((device) => device['deviceId'] == identity.id);
      if (localIndex >= 0) {
        devices[localIndex] = {
          ...devices[localIndex],
          'deviceId': identity.id,
          'name': identity.name,
        };
      } else {
        devices.add({
          'deviceId': identity.id,
          'name': identity.name,
          'lastSeen': DateTime.now().toIso8601String(),
        });
      }
    }

    devices.sort((a, b) {
      final aIsLocal = a['deviceId'] == identity.id;
      final bIsLocal = b['deviceId'] == identity.id;
      if (aIsLocal != bIsLocal) return aIsLocal ? -1 : 1;

      final aSeen = DateTime.tryParse(a['lastSeen'] as String? ?? '');
      final bSeen = DateTime.tryParse(b['lastSeen'] as String? ?? '');
      return (bSeen ?? DateTime.fromMillisecondsSinceEpoch(0))
          .compareTo(aSeen ?? DateTime.fromMillisecondsSinceEpoch(0));
    });

    if (mounted) {
      setState(() {
        _devices = devices;
        _localDeviceId = identity.id;
        _loaded = true;
      });
    }
  }

  String _formatLastSeen(String? isoString) {
    if (isoString == null) return 'Unknown';
    try {
      final dt = DateTime.parse(isoString);
      final now = DateTime.now();
      final diff = now.difference(dt);
      if (diff.inMinutes < 1) return 'Just now';
      if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
      if (diff.inHours < 24) return '${diff.inHours}h ago';
      if (diff.inDays < 7) return '${diff.inDays}d ago';
      return '${dt.day}/${dt.month}/${dt.year}';
    } catch (_) {
      return 'Unknown';
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const ListTile(
        leading: Icon(Icons.phone_android),
        title: Text('Loading devices...'),
      );
    }

    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      children: _devices.map((device) {
        final isThisDevice = device['deviceId'] == _localDeviceId;
        final name = (device['name'] as String?) ??
            (device['deviceName'] as String?) ??
            'Unknown Device';
        final lastSeen = _formatLastSeen(
          device['lastSeen'] as String? ?? device['lastSeenAt'] as String?,
        );

        return ListTile(
          leading: Icon(
            isThisDevice ? Icons.phone_android : Icons.devices_other,
            color: isThisDevice ? colorScheme.primary : null,
          ),
          title: Row(
            children: [
              Text(name),
              if (isThisDevice) ...[
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'This Device',
                    style: TextStyle(
                      fontSize: 10,
                      color: colorScheme.onPrimaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ],
          ),
          subtitle: Text('Last seen: $lastSeen'),
          onTap: isThisDevice ? () => _editDeviceName(context) : null,
        );
      }).toList(),
    );
  }

  void _editDeviceName(BuildContext context) {
    final controller = TextEditingController(
      text: _devices.firstWhere(
        (d) => d['deviceId'] == _localDeviceId,
        orElse: () => {'name': 'This Device'},
      )['name'] as String?,
    );
    final nameFocus = FocusNode();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename This Device'),
        content: PointerFocus(
          focusNode: nameFocus,
          child: TextField(
            controller: controller,
            focusNode: nameFocus,
            decoration: const InputDecoration(
              labelText: 'Device Name',
              border: OutlineInputBorder(),
            ),
            autofocus: true,
            textCapitalization: TextCapitalization.words,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                final keyStorage = ref.read(keyStorageProvider);
                await keyStorage.storeLocalDeviceName(name);
                Navigator.pop(ctx);
                _loadDevices(uploadCurrent: true);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ).whenComplete(() {
      controller.dispose();
      nameFocus.dispose();
    });
  }
}

class _WebOnlySettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _WebOnlySettingsTile({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Semantics(
      enabled: false,
      label: '$title, Android only. $subtitle',
      child: ListTile(
        enabled: false,
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: colorScheme.outlineVariant),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: Text(
              'Android',
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
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
