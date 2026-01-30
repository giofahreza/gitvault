import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Screen for linking a new device via QR code + PIN
class LinkDeviceScreen extends ConsumerStatefulWidget {
  const LinkDeviceScreen({super.key});

  @override
  ConsumerState<LinkDeviceScreen> createState() => _LinkDeviceScreenState();
}

class _LinkDeviceScreenState extends ConsumerState<LinkDeviceScreen> {
  bool _isSource = true; // true = showing QR, false = scanning QR

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
class _ShowQRView extends ConsumerWidget {
  const _ShowQRView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // TODO: Generate actual QR data using BlindHandshake
    const mockQRData = 'mock-encrypted-payload';
    const mockPIN = '123456';

    return Center(
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
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: QrImageView(
              data: mockQRData,
              version: QrVersions.auto,
              size: 250,
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
              color: Colors.deepPurple.shade100,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              mockPIN,
              style: const TextStyle(
                fontSize: 36,
                fontWeight: FontWeight.bold,
                letterSpacing: 8,
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'This code expires in 5 minutes',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
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

    // Show PIN entry after QR scan
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.check_circle, size: 64, color: Colors.green),
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
              onPressed: _verifyAndLink,
              child: const Text('Link Device'),
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: () => setState(() => _scannedData = null),
              child: const Text('Scan Again'),
            ),
          ],
        ),
      ),
    );
  }

  void _verifyAndLink() {
    if (_pinController.text.length != 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('PIN must be 6 digits')),
      );
      return;
    }

    // TODO: Decrypt QR data with PIN using BlindHandshake
    // TODO: Store root key and GitHub credentials
    // TODO: Generate validation TOTP and verify with source device

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Device linked successfully!')),
    );

    Navigator.of(context).pop();
  }
}
