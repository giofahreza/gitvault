import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/providers/providers.dart';
import '../../core/crypto/blind_handshake.dart';
import '../../core/services/background_sync_service.dart';

/// Screen for linking a new device via QR code + PIN
class LinkDeviceScreen extends ConsumerStatefulWidget {
  const LinkDeviceScreen({super.key});

  @override
  ConsumerState<LinkDeviceScreen> createState() => _LinkDeviceScreenState();
}

class _LinkDeviceScreenState extends ConsumerState<LinkDeviceScreen> {
  bool _isSource = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Link New Device'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: true,
                  label: Text('This Device'),
                  icon: Icon(Icons.qr_code),
                ),
                ButtonSegment(
                  value: false,
                  label: Text('New Device'),
                  icon: Icon(Icons.qr_code_scanner),
                ),
              ],
              selected: {_isSource},
              onSelectionChanged: (Set<bool> selected) {
                setState(() => _isSource = selected.first);
              },
            ),
          ),
          Expanded(
            child: _isSource ? const _ShowQRView() : const _ScanQRView(),
          ),
        ],
      ),
    );
  }
}

/// View for displaying QR code on the source device
class _ShowQRView extends ConsumerStatefulWidget {
  const _ShowQRView();

  @override
  ConsumerState<_ShowQRView> createState() => _ShowQRViewState();
}

class _ShowQRViewState extends ConsumerState<_ShowQRView> {
  LinkingPayload? _payload;
  bool _loading = true;
  String? _error;
  bool _hasGitHub = false;

  @override
  void initState() {
    super.initState();
    _generatePayload();
  }

  Future<void> _generatePayload() async {
    try {
      final keyStorage = ref.read(keyStorageProvider);
      final blindHandshake = ref.read(blindHandshakeProvider);

      await keyStorage.initialize();

      final rootKey = await keyStorage.getRootKey();
      if (rootKey == null) {
        setState(() {
          _error = 'No root key found. Set up the vault first.';
          _loading = false;
        });
        return;
      }

      // Read GitHub credentials from this device so they transfer to the new device
      final githubToken = await keyStorage.getGitHubToken() ?? '';
      final repoOwner = await keyStorage.getRepoOwner() ?? '';
      final repoName = await keyStorage.getRepoName() ?? '';
      final hasGitHub = githubToken.isNotEmpty && repoOwner.isNotEmpty && repoName.isNotEmpty;

      final payload = await blindHandshake.generateLinkingPayload(
        rootKey: rootKey,
        githubToken: githubToken,
        repoOwner: repoOwner,
        repoName: repoName,
      );

      if (mounted) {
        setState(() {
          _payload = payload;
          _hasGitHub = hasGitHub;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Failed to generate linking code: $e';
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      final colorScheme = Theme.of(context).colorScheme;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, size: 64, color: colorScheme.error),
              const SizedBox(height: 16),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: () {
                setState(() { _loading = true; _error = null; });
                _generatePayload();
              }, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    final payload = _payload!;
    final colorScheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                'Scan this QR code on your new device',
                style: TextStyle(fontSize: 18),
              ),
              const SizedBox(height: 16),

              // Show what will be transferred
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: _hasGitHub
                      ? colorScheme.secondaryContainer
                      : colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _hasGitHub ? Icons.cloud_done : Icons.cloud_off,
                      size: 18,
                      color: _hasGitHub
                          ? colorScheme.onSecondaryContainer
                          : colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _hasGitHub
                          ? 'GitHub sync config will transfer automatically'
                          : 'GitHub sync not configured on this device',
                      style: TextStyle(
                        fontSize: 12,
                        color: _hasGitHub
                            ? colorScheme.onSecondaryContainer
                            : colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: colorScheme.surface,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: QrImageView(
                  data: payload.qrData,
                  version: QrVersions.auto,
                  size: 250,
                  eyeStyle: QrEyeStyle(color: colorScheme.onSurface),
                  dataModuleStyle: QrDataModuleStyle(color: colorScheme.onSurface),
                ),
              ),
              const SizedBox(height: 32),
              const Text(
                'Then enter this PIN:',
                style: TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                decoration: BoxDecoration(
                  color: colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  payload.displayPIN,
                  style: const TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 8,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'This code expires in 5 minutes',
                style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 24),
              OutlinedButton.icon(
                onPressed: () {
                  setState(() { _loading = true; _error = null; _payload = null; _hasGitHub = false; });
                  _generatePayload();
                },
                icon: const Icon(Icons.refresh),
                label: const Text('Generate New Code'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// View for scanning QR code on the new device
class _ScanQRView extends ConsumerStatefulWidget {
  const _ScanQRView();

  @override
  ConsumerState<_ScanQRView> createState() => _ScanQRViewState();
}

class _ScanQRViewState extends ConsumerState<_ScanQRView> {
  final _pinController = TextEditingController();
  String? _scannedData;
  bool _linking = false;
  String _statusMessage = '';

  @override
  void dispose() {
    _pinController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_scannedData == null) {
      return MobileScanner(
        onDetect: (capture) {
          final List<Barcode> barcodes = capture.barcodes;
          for (final barcode in barcodes) {
            if (barcode.rawValue != null) {
              setState(() => _scannedData = barcode.rawValue);
              break;
            }
          }
        },
      );
    }

    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.check_circle, size: 64, color: colorScheme.tertiary),
            const SizedBox(height: 16),
            const Text(
              'QR Code Scanned!',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 32),
            const Text('Now enter the 6-digit PIN shown on the other device:'),
            const SizedBox(height: 16),
            TextField(
              controller: _pinController,
              decoration: const InputDecoration(
                labelText: 'PIN',
                border: OutlineInputBorder(),
                counterText: '',
              ),
              keyboardType: TextInputType.number,
              maxLength: 6,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 24, letterSpacing: 8),
            ),
            const SizedBox(height: 24),
            if (_linking && _statusMessage.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        _statusMessage,
                        style: TextStyle(color: colorScheme.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            FilledButton(
              onPressed: _linking ? null : _verifyAndLink,
              child: _linking
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Link Device'),
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: _linking ? null : () => setState(() => _scannedData = null),
              child: const Text('Scan Again'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _verifyAndLink() async {
    if (_pinController.text.length != 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('PIN must be 6 digits')),
      );
      return;
    }

    setState(() {
      _linking = true;
      _statusMessage = 'Verifying PIN...';
    });

    try {
      final blindHandshake = ref.read(blindHandshakeProvider);
      final keyStorage = ref.read(keyStorageProvider);
      await keyStorage.initialize();

      // Decrypt QR data with PIN
      final linkingData = await blindHandshake.decryptLinkingPayload(
        qrData: _scannedData!,
        pin: _pinController.text,
      );

      // Store root key
      setState(() => _statusMessage = 'Storing encryption key...');
      await keyStorage.storeRootKey(linkingData.rootKey);

      // Auto-configure GitHub if credentials were included in the payload
      final hasGitHub = linkingData.githubToken.isNotEmpty &&
          linkingData.repoOwner.isNotEmpty &&
          linkingData.repoName.isNotEmpty;

      if (hasGitHub) {
        setState(() => _statusMessage = 'Configuring GitHub sync...');
        await keyStorage.storeGitHubCredentials(
          token: linkingData.githubToken,
          repoOwner: linkingData.repoOwner,
          repoName: linkingData.repoName,
        );
      }

      // Register this device with a name
      await keyStorage.storeLocalDeviceName('Linked Device');

      // Refresh state so the vault is accessible
      ref.invalidate(isVaultSetupProvider);
      ref.invalidate(vaultEntriesProvider);

      if (!mounted) return;

      // Prompt for device name
      final nameController = TextEditingController(text: 'Linked Device');
      final deviceName = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('Name This Device'),
          content: TextField(
            controller: nameController,
            decoration: const InputDecoration(
              labelText: 'Device Name',
              hintText: 'e.g., My Pixel, Work Phone',
              border: OutlineInputBorder(),
            ),
            autofocus: true,
            textCapitalization: TextCapitalization.words,
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx, nameController.text.trim()),
              child: const Text('Save'),
            ),
          ],
        ),
      );

      if (!mounted) return;

      if (deviceName != null && deviceName.isNotEmpty) {
        await keyStorage.storeLocalDeviceName(deviceName);
      }

      // If GitHub was configured, run an immediate sync to pull vault data
      if (hasGitHub) {
        setState(() => _statusMessage = 'Syncing vault from GitHub...');

        try {
          final result = await BackgroundSyncService.performSyncNow();

          if (mounted) {
            // Invalidate repository providers — cascades to all list providers
            // and forces fresh instances so newly synced Hive data is read.
            ref.invalidate(vaultRepositoryProvider);
            ref.invalidate(notesRepositoryProvider);
            ref.invalidate(sshRepositoryProvider);
            ref.invalidate(archivedNotesProvider);

            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Device linked! GitHub sync configured automatically. '
                  'Pulled ${result.pulled} item${result.pulled == 1 ? "" : "s"} from vault.',
                ),
                backgroundColor: Colors.green,
                duration: const Duration(seconds: 5),
              ),
            );
          }
        } catch (syncError) {
          // Sync failure is non-fatal — device is still linked and GitHub is configured
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Device linked! GitHub sync configured, but initial sync failed: $syncError\n'
                  'You can sync manually from Settings.',
                ),
                backgroundColor: Colors.orange,
                duration: const Duration(seconds: 6),
              ),
            );
          }
        }
      } else {
        // No GitHub credentials on source device
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Device linked! The source device has no GitHub sync configured. '
              'Set it up in Settings → GitHub Sync.',
            ),
            duration: Duration(seconds: 5),
          ),
        );
      }

      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        setState(() { _linking = false; _statusMessage = ''; });
        String message;
        if (e.toString().contains('expired')) {
          message = 'Code expired. Ask the other device to generate a new one.';
        } else if (e.toString().contains('MAC') || e.toString().contains('Decryption')) {
          message = 'Wrong PIN. Please try again.';
        } else {
          message = 'Linking failed: $e';
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
    }
  }
}
