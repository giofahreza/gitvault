import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/providers/providers.dart';
import '../../core/crypto/blind_handshake.dart';
import '../../core/services/background_sync_service.dart';
import '../../utils/clipboard_feedback.dart';
import '../../utils/constants.dart';
import '../../utils/pointer_focus.dart';

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
            child: Semantics(
              container: true,
              label: 'Device linking role',
              value: _isSource
                  ? 'This device shows the QR code'
                  : 'This device scans or pastes the transfer code',
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
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              _isSource
                  ? 'Show QR from your existing device. The new device can scan it or paste a transfer code.'
                  : 'On the new device, scan the QR or paste the transfer code from your existing device.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 8),
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
  bool _showTransferCode = false;
  bool _transferCodeCopied = false;
  final _scrollController = ScrollController();
  Timer? _copyFeedbackTimer;

  @override
  void initState() {
    super.initState();
    _generatePayload();
  }

  @override
  void dispose() {
    _copyFeedbackTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _toggleTransferCode() {
    setState(() => _showTransferCode = !_showTransferCode);
    if (!_showTransferCode) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
    });
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
      final hasGitHub =
          githubToken.isNotEmpty && repoOwner.isNotEmpty && repoName.isNotEmpty;

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

  void _refreshPayload() {
    setState(() {
      _loading = true;
      _error = null;
      _payload = null;
      _hasGitHub = false;
      _showTransferCode = false;
      _transferCodeCopied = false;
    });
    _generatePayload();
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
              FilledButton(
                  onPressed: () {
                    setState(() {
                      _loading = true;
                      _error = null;
                    });
                    _generatePayload();
                  },
                  child: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    final payload = _payload!;
    final colorScheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = MediaQuery.sizeOf(context).width < 520;
        final compact = constraints.maxHeight < 680 || narrow;
        final revealCompact = _showTransferCode && constraints.maxHeight < 760;
        final qrSize = narrow
            ? (_showTransferCode ? 150.0 : 210.0)
            : (revealCompact ? 150.0 : (compact ? 180.0 : 250.0));
        final pagePadding = narrow ? 12.0 : (compact ? 16.0 : 24.0);
        final sectionGap = revealCompact || narrow ? 12.0 : 24.0;
        final pinFontSize =
            narrow ? 32.0 : (revealCompact ? 28.0 : (compact ? 30.0 : 36.0));

        return Scrollbar(
          controller: _scrollController,
          thumbVisibility: kIsWeb,
          child: SingleChildScrollView(
            controller: _scrollController,
            padding: EdgeInsets.only(bottom: sectionGap),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Padding(
                  padding: EdgeInsets.all(pagePadding),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text(
                        'Scan this QR code on your new device',
                        style: TextStyle(fontSize: 18),
                      ),
                      const SizedBox(height: 16),

                      // Show what will be transferred
                      Semantics(
                        container: true,
                        label: 'GitHub sync transfer status',
                        value: _hasGitHub
                            ? 'GitHub sync config will transfer automatically'
                            : 'GitHub sync is not configured on this device',
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 10),
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
                      ),
                      SizedBox(height: sectionGap),

                      Semantics(
                        image: true,
                        label: 'Device linking QR code',
                        value: 'Scan this code on the new device',
                        child: Container(
                          padding: EdgeInsets.all(compact ? 10 : 16),
                          decoration: BoxDecoration(
                            color: colorScheme.surface,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: ExcludeSemantics(
                            child: QrImageView(
                              data: payload.qrData,
                              version: QrVersions.auto,
                              size: qrSize,
                              eyeStyle:
                                  QrEyeStyle(color: colorScheme.onSurface),
                              dataModuleStyle: QrDataModuleStyle(
                                  color: colorScheme.onSurface),
                            ),
                          ),
                        ),
                      ),
                      SizedBox(height: compact ? 18 : 32),
                      const Text(
                        'Then enter this PIN:',
                        style: TextStyle(fontSize: 16),
                      ),
                      const SizedBox(height: 8),
                      Semantics(
                        container: true,
                        label: 'Device linking PIN',
                        value: payload.displayPIN.split('').join(' '),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 24, vertical: 12),
                          decoration: BoxDecoration(
                            color: colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: ExcludeSemantics(
                            child: Text(
                              payload.displayPIN,
                              style: TextStyle(
                                fontSize: pinFontSize,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 8,
                              ),
                            ),
                          ),
                        ),
                      ),
                      SizedBox(height: compact ? 12 : 16),
                      Text(
                        'This code expires in 5 minutes',
                        style: TextStyle(
                            fontSize: 12, color: colorScheme.onSurfaceVariant),
                      ),
                      SizedBox(height: compact ? 12 : 16),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'No camera on the new device?',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Copy this transfer code and paste it on the new device.',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: colorScheme.onSurfaceVariant),
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                Tooltip(
                                  message: 'Copy transfer code',
                                  child: FilledButton.tonalIcon(
                                    onPressed: () async {
                                      final copied =
                                          await copyTextWithFeedback(
                                        context,
                                        text: payload.qrData,
                                        successMessage:
                                            'Transfer code copied',
                                        failureMessage:
                                            'Could not copy transfer code. Show the code and copy it manually instead.',
                                        margin: const EdgeInsets.fromLTRB(
                                            16, 0, 16, 88),
                                      );
                                      if (!mounted) return;
                                      if (!copied) return;
                                      _copyFeedbackTimer?.cancel();
                                      setState(
                                          () => _transferCodeCopied = true);
                                      _copyFeedbackTimer = Timer(
                                        const Duration(seconds: 2),
                                        () {
                                          if (mounted) {
                                            setState(() =>
                                                _transferCodeCopied = false);
                                          }
                                        },
                                      );
                                    },
                                    icon: Icon(_transferCodeCopied
                                        ? Icons.check
                                        : Icons.copy),
                                    label: Text(_transferCodeCopied
                                        ? 'Copied'
                                        : 'Copy Code'),
                                  ),
                                ),
                                Tooltip(
                                  message: _showTransferCode
                                      ? 'Hide transfer code'
                                      : 'Show transfer code',
                                  child: OutlinedButton.icon(
                                    onPressed: _toggleTransferCode,
                                    icon: Icon(_showTransferCode
                                        ? Icons.visibility_off
                                        : Icons.visibility),
                                    label: Text(_showTransferCode
                                        ? 'Hide Code'
                                        : 'Show Code'),
                                  ),
                                ),
                                Tooltip(
                                  message: 'Generate a fresh QR code and PIN',
                                  child: OutlinedButton.icon(
                                    onPressed: _refreshPayload,
                                    icon: const Icon(Icons.refresh),
                                    label: const Text('Generate New Code'),
                                  ),
                                ),
                              ],
                            ),
                            if (_showTransferCode) ...[
                              const SizedBox(height: 10),
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: colorScheme.surface,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                      color: colorScheme.outlineVariant),
                                ),
                                constraints:
                                    const BoxConstraints(maxHeight: 140),
                                child: Semantics(
                                  textField: true,
                                  readOnly: true,
                                  label: 'Transfer code text',
                                  child: SingleChildScrollView(
                                    child: SelectableText(
                                      payload.qrData,
                                      style: const TextStyle(
                                          fontSize: 11,
                                          fontFamily: 'monospace'),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

enum _LinkInputMethod { scan, paste }

/// View for scanning QR code on the new device
class _ScanQRView extends ConsumerStatefulWidget {
  const _ScanQRView();

  @override
  ConsumerState<_ScanQRView> createState() => _ScanQRViewState();
}

class _ScanQRViewState extends ConsumerState<_ScanQRView> {
  final _pinController = TextEditingController();
  final _codeController = TextEditingController();
  final _pinFocus = FocusNode();
  final _codeFocus = FocusNode();
  String? _scannedData;
  String? _codeError;
  String? _pinError;
  late _LinkInputMethod _inputMethod;
  bool _linking = false;
  String _statusMessage = '';

  @override
  void initState() {
    super.initState();
    _inputMethod = kIsWeb ? _LinkInputMethod.paste : _LinkInputMethod.scan;
  }

  @override
  void dispose() {
    _pinController.clear();
    _codeController.clear();
    _pinController.dispose();
    _codeController.dispose();
    _pinFocus.dispose();
    _codeFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_scannedData == null) {
      return _buildCaptureStep(context);
    }

    return _buildPinStep(context);
  }

  Widget _buildCaptureStep(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Semantics(
            container: true,
            label: 'Transfer code input method',
            value: _inputMethod == _LinkInputMethod.scan
                ? 'Scan QR'
                : 'Paste code',
            child: SegmentedButton<_LinkInputMethod>(
              segments: [
                if (!kIsWeb)
                  const ButtonSegment(
                    value: _LinkInputMethod.scan,
                    icon: Icon(Icons.qr_code_scanner),
                    label: Text('Scan QR'),
                  ),
                const ButtonSegment(
                  value: _LinkInputMethod.paste,
                  icon: Icon(Icons.paste),
                  label: Text('Paste Code'),
                ),
              ],
              selected: {_inputMethod},
              onSelectionChanged: (selected) {
                setState(() {
                  _inputMethod = selected.first;
                  _codeError = null;
                });
              },
            ),
          ),
          const SizedBox(height: 16),
          if (_inputMethod == _LinkInputMethod.scan) ...[
            Expanded(
              child: Semantics(
                label: 'QR scanner camera preview',
                value: 'Point camera at the QR code on the existing device',
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: MobileScanner(
                    onDetect: (capture) {
                      for (final barcode in capture.barcodes) {
                        if (barcode.rawValue != null) {
                          _acceptTransferCode(barcode.rawValue!);
                          break;
                        }
                      }
                    },
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Scan the QR shown on your existing device.',
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
            if (_codeError != null) ...[
              const SizedBox(height: 8),
              Text(
                _codeError!,
                style: TextStyle(color: colorScheme.error),
                textAlign: TextAlign.center,
              ),
            ],
            Tooltip(
              message: 'Switch to transfer code entry',
              child: TextButton.icon(
                onPressed: () =>
                    setState(() => _inputMethod = _LinkInputMethod.paste),
                icon: const Icon(Icons.paste),
                label: const Text('Use Transfer Code Instead'),
              ),
            ),
          ] else ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Paste transfer code',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'On the existing device, open Link Device and tap "Copy Code".',
                    style: TextStyle(
                        fontSize: 12, color: colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 12),
                  PointerFocus(
                    focusNode: _codeFocus,
                    child: TextField(
                      controller: _codeController,
                      focusNode: _codeFocus,
                      minLines: 4,
                      maxLines: 6,
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 12),
                      onChanged: (_) {
                        if (_codeError != null) {
                          setState(() => _codeError = null);
                        }
                      },
                      decoration: InputDecoration(
                        hintText: 'Paste transfer code here',
                        border: const OutlineInputBorder(),
                        errorText: _codeError,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      Tooltip(
                        message: 'Paste transfer code from clipboard',
                        child: OutlinedButton.icon(
                          onPressed: _pasteFromClipboard,
                          icon: const Icon(Icons.content_paste),
                          label: const Text('Paste from Clipboard'),
                        ),
                      ),
                      Tooltip(
                        message: 'Continue to PIN entry',
                        child: FilledButton(
                          onPressed: _acceptManualCode,
                          child: const Text('Continue'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'This is the same data as the QR code.',
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
            const Spacer(),
          ],
        ],
      ),
    );
  }

  Widget _buildPinStep(BuildContext context) {
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
              'Transfer Code Accepted',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 32),
            const Text('Now enter the 6-digit PIN shown on the other device:'),
            const SizedBox(height: 16),
            PointerFocus(
              focusNode: _pinFocus,
              child: TextField(
                controller: _pinController,
                focusNode: _pinFocus,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'PIN',
                  border: const OutlineInputBorder(),
                  counterText: '',
                  errorText: _pinError,
                ),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                maxLength: 6,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 24, letterSpacing: 8),
                textInputAction: TextInputAction.done,
                onChanged: (_) {
                  if (_pinError != null) {
                    setState(() => _pinError = null);
                  }
                },
                onSubmitted: (_) => _linking ? null : _verifyAndLink(),
              ),
            ),
            const SizedBox(height: 24),
            if (_linking && _statusMessage.isNotEmpty) ...[
              Semantics(
                liveRegion: true,
                label: 'Device linking status',
                value: _statusMessage,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(
                        width: 16,
                        height: 16,
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
              ),
            ],
            Tooltip(
              message: 'Verify PIN and link this device',
              child: FilledButton(
                onPressed: _linking ? null : _verifyAndLink,
                child: _linking
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Text('Link Device'),
              ),
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: _linking
                  ? null
                  : () => setState(() {
                        _scannedData = null;
                        _pinController.clear();
                        _pinError = null;
                      }),
              child: const Text('Use Another Code'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pasteFromClipboard() async {
    String? text;
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      text = data?.text?.trim();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Browser blocked clipboard access. Paste the transfer code manually.'),
        ),
      );
      return;
    }

    if (text == null || text.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Clipboard is empty')),
      );
      return;
    }
    setState(() {
      _codeController.text = text!;
      _codeError = null;
    });
  }

  void _acceptManualCode() {
    final code = _codeController.text.trim();
    _acceptTransferCode(code);
  }

  void _acceptTransferCode(String code) {
    final trimmed = code.trim();
    if (trimmed.isEmpty) {
      setState(() => _codeError = 'Please paste transfer code first');
      return;
    }

    if (!_looksLikeTransferCode(trimmed)) {
      setState(() {
        _codeError =
            'This is not a valid GitVault transfer code. Copy the full code from Link New Device.';
      });
      return;
    }

    setState(() {
      _scannedData = trimmed;
      _codeError = null;
      _pinError = null;
    });
  }

  bool _looksLikeTransferCode(String code) {
    try {
      final bytes = base64Decode(code);
      return bytes.length > Constants.nonceSize + Constants.macSize;
    } catch (_) {
      return false;
    }
  }

  Future<void> _verifyAndLink() async {
    if (_pinController.text.length != 6) {
      setState(() => _pinError = 'PIN must be 6 digits');
      return;
    }

    setState(() {
      _linking = true;
      _statusMessage = 'Verifying PIN...';
      _pinError = null;
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
      final nameFocus = FocusNode();
      final deviceName = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('Name This Device'),
          content: PointerFocus(
            focusNode: nameFocus,
            child: TextField(
              controller: nameController,
              focusNode: nameFocus,
              decoration: const InputDecoration(
                labelText: 'Device Name',
                hintText: 'e.g., My Pixel, Work Phone',
                border: OutlineInputBorder(),
              ),
              autofocus: true,
              textCapitalization: TextCapitalization.words,
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx, nameController.text.trim()),
              child: const Text('Save'),
            ),
          ],
        ),
      );

      nameController.clear();
      nameController.dispose();
      nameFocus.dispose();

      if (!mounted) return;

      if (deviceName != null && deviceName.isNotEmpty) {
        await keyStorage.storeLocalDeviceName(deviceName);
      }

      // If GitHub was configured, run an immediate sync to pull vault data
      if (hasGitHub) {
        if (kIsWeb) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Device linked and GitHub sync configured. Run sync manually from Settings on web.',
              ),
              duration: Duration(seconds: 5),
            ),
          );
        } else {
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
        setState(() {
          _linking = false;
          _statusMessage = '';
        });
        _pinController.clear();
        String message;
        if (e.toString().contains('expired')) {
          message = 'Code expired. Ask the other device to generate a new one.';
        } else if (e.toString().contains('MAC') ||
            e.toString().contains('Decryption')) {
          message = 'Wrong PIN. Please try again.';
        } else {
          message = 'Linking failed: $e';
        }
        setState(() => _pinError = message);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
    }
  }
}
