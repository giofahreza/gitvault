import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/providers/providers.dart';
import '../../core/crypto/blind_handshake.dart';

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

  @override
  void initState() {
    super.initState();
    _generatePayload();
  }

  Future<void> _generatePayload() async {
    try {
      final keyStorage = ref.read(keyStorageProvider);
      final blindHandshake = ref.read(blindHandshakeProvider);

      final rootKey = await keyStorage.getRootKey();
      if (rootKey == null) {
        setState(() {
          _error = 'No root key found. Set up the vault first.';
          _loading = false;
        });
        return;
      }

      // Only transfer root key, not GitHub credentials
      // User must manually set up GitHub sync on each device
      final payload = await blindHandshake.generateLinkingPayload(
        rootKey: rootKey,
        githubToken: '',
        repoOwner: '',
        repoName: '',
      );

      if (mounted) {
        setState(() {
          _payload = payload;
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
              const SizedBox(height: 32),
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
                  setState(() { _loading = true; _error = null; _payload = null; });
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
            FilledButton(
              onPressed: _linking ? null : _verifyAndLink,
              child: _linking
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
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

    setState(() => _linking = true);

    try {
      final blindHandshake = ref.read(blindHandshakeProvider);
      final keyStorage = ref.read(keyStorageProvider);

      // Decrypt QR data with PIN
      final linkingData = await blindHandshake.decryptLinkingPayload(
        qrData: _scannedData!,
        pin: _pinController.text,
      );

      // Store only the root key on this device (not GitHub credentials)
      // User must manually set up GitHub sync on each device if desired
      await keyStorage.storeRootKey(linkingData.rootKey);

      // Refresh setup state
      ref.invalidate(isVaultSetupProvider);
      ref.invalidate(vaultEntriesProvider);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Device linked successfully! Set up GitHub sync in Settings to sync your vault.')),
        );
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _linking = false);
        String message = 'Linking failed';
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
