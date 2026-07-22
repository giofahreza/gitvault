import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../utils/pointer_focus.dart';

/// QR scanner screen for scanning TOTP otpauth:// URIs
class TotpScannerScreen extends StatefulWidget {
  const TotpScannerScreen({super.key});

  @override
  State<TotpScannerScreen> createState() => _TotpScannerScreenState();
}

class _TotpScannerScreenState extends State<TotpScannerScreen> {
  final MobileScannerController _controller = MobileScannerController();
  final _uriController = TextEditingController();
  final _uriFocus = FocusNode();
  bool _hasScanned = false;
  String? _webError;

  @override
  void dispose() {
    _controller.dispose();
    _uriController.clear();
    _uriController.dispose();
    _uriFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) {
      return _buildWebFallback(context);
    }

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

  Widget _buildWebFallback(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Add 2FA from QR'),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  Icons.qr_code_2,
                  size: 72,
                  color: colorScheme.primary,
                ),
                const SizedBox(height: 16),
                const Text(
                  'Paste an OTP setup link',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
                  'On web, paste an otpauth:// link or Google Authenticator migration link from another app.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 24),
                PointerFocus(
                  focusNode: _uriFocus,
                  child: TextField(
                    controller: _uriController,
                    focusNode: _uriFocus,
                    minLines: 4,
                    maxLines: 6,
                    autofocus: true,
                    style:
                        const TextStyle(fontFamily: 'monospace', fontSize: 12),
                    decoration: InputDecoration(
                      labelText: 'OTP setup link',
                      hintText: 'otpauth://totp/Example:user@example.com?...',
                      border: const OutlineInputBorder(),
                      errorText: _webError,
                      alignLabelWithHint: true,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.end,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _pasteOtpLink,
                      icon: const Icon(Icons.content_paste),
                      label: const Text('Paste'),
                    ),
                    FilledButton.icon(
                      onPressed: _submitOtpLink,
                      icon: const Icon(Icons.check),
                      label: const Text('Continue'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _pasteOtpLink() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim();
      if (!mounted) return;
      if (text == null || text.isEmpty) {
        setState(() => _webError = 'Clipboard is empty');
        return;
      }
      setState(() {
        _uriController.text = text;
        _webError = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _webError =
          'Browser blocked clipboard access. Paste the setup link manually.');
    }
  }

  void _submitOtpLink() {
    final value = _uriController.text.trim();
    if (value.isEmpty) {
      setState(() => _webError = 'Paste an OTP setup link first');
      return;
    }
    if (!_handleDetectedValue(value)) {
      setState(
          () => _webError = 'Enter a valid otpauth:// or migration setup link');
    }
  }

  void _onDetect(BarcodeCapture capture) {
    if (_hasScanned) return;

    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value == null) continue;

      if (_handleDetectedValue(value)) return;
    }
  }

  bool _handleDetectedValue(String value) {
    // Check for otpauth:// URI
    if (value.startsWith('otpauth://totp/') ||
        value.startsWith('otpauth://hotp/')) {
      _hasScanned = true;
      final parsed = _parseOtpauthUri(value);
      if (parsed != null) {
        Navigator.pop(context, parsed);
      } else {
        if (!kIsWeb) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Invalid TOTP QR code')),
          );
        }
        _hasScanned = false;
      }
      return parsed != null;
    }

    // Check for Google Authenticator migration format
    if (value.startsWith('otpauth-migration://')) {
      _hasScanned = true;
      Navigator.pop(context, {'migration': value});
      return true;
    }

    return false;
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
