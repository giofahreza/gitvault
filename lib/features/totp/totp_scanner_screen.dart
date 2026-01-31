import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// QR scanner screen for scanning TOTP otpauth:// URIs
class TotpScannerScreen extends StatefulWidget {
  const TotpScannerScreen({super.key});

  @override
  State<TotpScannerScreen> createState() => _TotpScannerScreenState();
}

class _TotpScannerScreenState extends State<TotpScannerScreen> {
  final MobileScannerController _controller = MobileScannerController();
  bool _hasScanned = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan QR Code'),
        actions: [
          IconButton(
            icon: ValueListenableBuilder(
              valueListenable: _controller.torchState,
              builder: (_, state, __) {
                return Icon(
                  state == TorchState.on ? Icons.flash_on : Icons.flash_off,
                );
              },
            ),
            onPressed: () => _controller.toggleTorch(),
          ),
          IconButton(
            icon: const Icon(Icons.flip_camera_android),
            onPressed: () => _controller.switchCamera(),
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
          ),
          // Overlay with scanning frame
          Center(
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 2),
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          Positioned(
            bottom: 80,
            left: 0,
            right: 0,
            child: Text(
              'Point camera at a TOTP QR code',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                backgroundColor: Colors.black54,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _onDetect(BarcodeCapture capture) {
    if (_hasScanned) return;

    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value == null) continue;

      // Check for otpauth:// URI
      if (value.startsWith('otpauth://totp/') || value.startsWith('otpauth://hotp/')) {
        _hasScanned = true;
        final parsed = _parseOtpauthUri(value);
        if (parsed != null) {
          Navigator.pop(context, parsed);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Invalid TOTP QR code')),
          );
          _hasScanned = false;
        }
        return;
      }

      // Check for Google Authenticator migration format
      if (value.startsWith('otpauth-migration://')) {
        _hasScanned = true;
        Navigator.pop(context, {'migration': value});
        return;
      }
    }
  }

  Map<String, String>? _parseOtpauthUri(String uri) {
    try {
      final parsed = Uri.parse(uri);
      final secret = parsed.queryParameters['secret'];
      if (secret == null || secret.isEmpty) return null;

      // Path format: /issuer:account or /account
      var path = parsed.path;
      if (path.startsWith('/')) path = path.substring(1);
      path = Uri.decodeComponent(path);

      String issuer = parsed.queryParameters['issuer'] ?? '';
      String account = '';

      if (path.contains(':')) {
        final parts = path.split(':');
        if (issuer.isEmpty) issuer = parts[0].trim();
        account = parts.length > 1 ? parts[1].trim() : '';
      } else {
        account = path;
      }

      return {
        'issuer': issuer,
        'account': account,
        'secret': secret,
        'digits': parsed.queryParameters['digits'] ?? '6',
        'period': parsed.queryParameters['period'] ?? '30',
        'algorithm': parsed.queryParameters['algorithm'] ?? 'SHA1',
      };
    } catch (_) {
      return null;
    }
  }
}
