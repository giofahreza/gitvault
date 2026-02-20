import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';
import '../../core/services/persistent_ssh_service.dart';

/// Enhanced SSH Terminal Screen with Termux-like features
/// - Persistent sessions with notifications
/// - Gestures for common operations
/// - Volume key bindings
/// - Enhanced keyboard toolbar
class SshPersistentTerminalScreen extends StatefulWidget {
  final SshSessionWrapper session;

  const SshPersistentTerminalScreen({super.key, required this.session});

  @override
  State<SshPersistentTerminalScreen> createState() => _SshPersistentTerminalScreenState();
}

class _SshPersistentTerminalScreenState extends State<SshPersistentTerminalScreen>
    with WidgetsBindingObserver {
  late final Terminal _terminal;
  late final TerminalController _terminalController;
  late final FocusNode _terminalFocusNode;

  StreamSubscription? _stdoutSubscription;
  StreamSubscription? _stderrSubscription;

  bool _hasAttachedBefore = false;

  // Modifier key states
  bool _ctrlActive = false;
  bool _altActive = false;

  // Terminal settings
  double _fontSize = 12.0;

  // Gesture detection
  static const _volumeKeyChannel = MethodChannel('com.giofahreza.gitvault/volume_keys');
  static const _imeChannel = MethodChannel('com.giofahreza.gitvault/ime');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Use persistent terminal from session wrapper - preserves scrollback like Termux!
    _terminal = widget.session.terminal;
    _terminalController = TerminalController();
    _terminalFocusNode = FocusNode();

    // Set up volume key listener
    _setupVolumeKeys();

    // Connect to existing session
    _connectToSession();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stdoutSubscription?.cancel();
    _stderrSubscription?.cancel();
    _terminalController.dispose();
    _terminalFocusNode.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Reconnect if needed (reconnect() is a no-op if already connecting)
      if (!widget.session.isConnected && !widget.session.isConnecting) {
        widget.session.reconnect();
      }
    }
  }

  void _setupVolumeKeys() {
    // Listen for volume key events (requires native implementation)
    _volumeKeyChannel.setMethodCallHandler((call) async {
      if (call.method == 'volumeDown') {
        _handleVolumeDown();
      } else if (call.method == 'volumeUp') {
        _handleVolumeUp();
      }
    });
  }

  void _handleVolumeDown() {
    // Volume Down = Ctrl+C (like Termux)
    _sendRaw([0x03]); // Ctrl+C
  }

  void _handleVolumeUp() {
    // Volume Up = Ctrl+D (like Termux)
    _sendRaw([0x04]); // Ctrl+D
  }

  Future<void> _connectToSession() async {
    debugPrint('[Terminal] Attaching to session. isConnected=${widget.session.isConnected}, managerConnected=${widget.session.connectionManager.isConnected}, isConnecting=${widget.session.isConnecting}');

    // If a connection is already in progress (started by createSession), wait for it
    if (widget.session.isConnecting) {
      if (!_hasAttachedBefore) {
        _terminal.write('Connecting to ${widget.session.credential.host}...\r\n');
        _hasAttachedBefore = true;
      }
      try {
        await widget.session.stateStream.firstWhere(
          (s) => s == SshSessionState.connected ||
                 s == SshSessionState.error ||
                 s == SshSessionState.disconnected,
        );
      } catch (_) {}
    } else if (!widget.session.isConnected || !widget.session.connectionManager.isConnected) {
      // Only reconnect if truly disconnected (not just connecting)
      if (_hasAttachedBefore) {
        _terminal.write('Reconnecting to ${widget.session.credential.host}...\r\n');
      } else {
        _terminal.write('Connecting to ${widget.session.credential.host}...\r\n');
      }

      try {
        await widget.session.reconnect();
        _terminal.write('Connected. Session active.\r\n');
        _hasAttachedBefore = true;
      } catch (e) {
        _terminal.write('\r\nConnection failed: $e\r\n');
        _terminal.write('Tap the reconnect button in the toolbar to retry\r\n');
        return;
      }
    } else if (!_hasAttachedBefore) {
      // First time attaching to an already-connected session
      _terminal.write('Attached to ${widget.session.credential.host}\r\n');
      _hasAttachedBefore = true;
    }
    // If already attached before and still connected, don't show any message
    // This prevents spam when navigating back to the terminal

    final session = widget.session.connectionManager.session;
    if (session == null) {
      _terminal.write('\r\nSession not available. Connection may have timed out.\r\n');
      _terminal.write('Tap the reconnect button in the toolbar to retry\r\n');
      return;
    }

    debugPrint('[Terminal] Session attached successfully');

    // Subscribe to broadcast streams from session wrapper
    // These streams persist across terminal screen instances
    _stdoutSubscription?.cancel();
    _stdoutSubscription = utf8.decoder.bind(widget.session.stdout).listen(
      (data) {
        if (mounted) {
          _terminal.write(data);
        }
      },
      onError: (e) {
        if (mounted) {
          _terminal.write('\r\n[Output error: $e]\r\n');
        }
      },
      cancelOnError: false,
    );

    _stderrSubscription?.cancel();
    _stderrSubscription = utf8.decoder.bind(widget.session.stderr).listen(
      (data) {
        if (mounted) {
          _terminal.write(data);
        }
      },
      onError: (e) {
        if (mounted) {
          _terminal.write('\r\n[Error: $e]\r\n');
        }
      },
      cancelOnError: false,
    );

    // Pipe terminal input with modifier support
    _terminal.onOutput = (data) {
      if (_ctrlActive) {
        final bytes = <int>[];
        for (final char in data.codeUnits) {
          if (char >= 97 && char <= 122) {
            bytes.add(char - 96);
          } else if (char >= 65 && char <= 90) {
            bytes.add(char - 64);
          } else {
            bytes.add(char);
          }
        }
        session.write(Uint8List.fromList(bytes));
        setState(() => _ctrlActive = false);
        return;
      }

      if (_altActive) {
        final bytes = <int>[];
        for (final byte in utf8.encode(data)) {
          bytes.add(0x1B);
          bytes.add(byte);
        }
        session.write(Uint8List.fromList(bytes));
        setState(() => _altActive = false);
        return;
      }

      session.write(Uint8List.fromList(utf8.encode(data)));
    };

    // Handle terminal resize
    _terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      session.resizeTerminal(width, height);
    };

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _terminalFocusNode.requestFocus();
    });
  }

  void _sendRaw(List<int> bytes) {
    widget.session.connectionManager.session?.write(Uint8List.fromList(bytes));
  }

  void _sendKey(String key) {
    if (_ctrlActive) {
      final code = key.toUpperCase().codeUnitAt(0);
      if (code >= 65 && code <= 90) {
        _sendRaw([code - 64]);
      }
      setState(() => _ctrlActive = false);
      return;
    }

    if (_altActive) {
      _sendRaw([0x1B, ...utf8.encode(key)]);
      setState(() => _altActive = false);
      return;
    }

    _sendRaw(utf8.encode(key));
  }

  Future<void> _showKeyboardPicker() async {
    try {
      await _imeChannel.invokeMethod('showKeyboardPicker');
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: GestureDetector(
          onLongPress: _showContextMenu,
          child: Column(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: () => _terminalFocusNode.requestFocus(),
                  onScaleUpdate: (details) {
                    setState(() {
                      _fontSize = (_fontSize * details.scale).clamp(8.0, 24.0);
                    });
                  },
                  child: TerminalView(
                    _terminal,
                    controller: _terminalController,
                    focusNode: _terminalFocusNode,
                    textStyle: TerminalStyle(
                      fontSize: _fontSize,
                      fontFamily: 'JetBrainsMonoNerd',
                    ),
                  ),
                ),
              ),
              _buildKeyboardToolbar(Theme.of(context).colorScheme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildKeyboardToolbar(ColorScheme colorScheme) {
    return Container(
      color: colorScheme.surfaceContainerHighest,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 44,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // ── Navigation ────────────────────────────────────────────
                _buildIconKey(Icons.more_vert, _showContextMenu, colorScheme),
                // Connection status
                StreamBuilder<SshSessionState>(
                  stream: widget.session.stateStream,
                  initialData: widget.session.isConnected
                      ? SshSessionState.connected
                      : SshSessionState.disconnected,
                  builder: (context, snapshot) {
                    final state = snapshot.data ?? SshSessionState.disconnected;
                    if (state == SshSessionState.connecting) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8),
                        child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                      );
                    } else if (state == SshSessionState.connected) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8),
                        child: Icon(Icons.circle, color: Colors.green, size: 10),
                      );
                    } else {
                      return _buildIconKey(Icons.refresh, _connectToSession, colorScheme);
                    }
                  },
                ),
                // Session label
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Text(
                    '${widget.session.credential.username}@${widget.session.credential.host}',
                    style: TextStyle(fontSize: 12, color: colorScheme.onSurface),
                    maxLines: 1,
                  ),
                ),
                // ── Keys (only when connected) ────────────────────────────
                if (widget.session.isConnected) ...[
                  _buildDivider(colorScheme),
                  _buildKey('Paste', _pasteFromClipboard, colorScheme),
                  _buildKey('Copy', _copySelection, colorScheme),
                  _buildDivider(colorScheme),
                  _buildToggleKey('Ctrl', _ctrlActive, () {
                    setState(() => _ctrlActive = !_ctrlActive);
                  }, colorScheme),
                  _buildToggleKey('Alt', _altActive, () {
                    setState(() => _altActive = !_altActive);
                  }, colorScheme),
                  _buildDivider(colorScheme),
                  _buildKey('Esc', () => _sendRaw([0x1B]), colorScheme),
                  _buildKey('Tab', () => _sendRaw([0x09]), colorScheme),
                  _buildDivider(colorScheme),
                  _buildKey('↑', () => _sendRaw([0x1B, 0x5B, 0x41]), colorScheme),
                  _buildKey('↓', () => _sendRaw([0x1B, 0x5B, 0x42]), colorScheme),
                  _buildKey('←', () => _sendRaw([0x1B, 0x5B, 0x44]), colorScheme),
                  _buildKey('→', () => _sendRaw([0x1B, 0x5B, 0x43]), colorScheme),
                  _buildDivider(colorScheme),
                  _buildKey('Home', () => _sendRaw([0x1B, 0x5B, 0x48]), colorScheme),
                  _buildKey('End', () => _sendRaw([0x1B, 0x5B, 0x46]), colorScheme),
                  _buildKey('PgUp', () => _sendRaw([0x1B, 0x5B, 0x35, 0x7E]), colorScheme),
                  _buildKey('PgDn', () => _sendRaw([0x1B, 0x5B, 0x36, 0x7E]), colorScheme),
                  _buildDivider(colorScheme),
                  _buildKey('|', () => _sendKey('|'), colorScheme),
                  _buildKey('/', () => _sendKey('/'), colorScheme),
                  _buildKey('\\', () => _sendKey('\\'), colorScheme),
                  _buildKey('~', () => _sendKey('~'), colorScheme),
                  _buildKey('-', () => _sendKey('-'), colorScheme),
                  _buildKey('_', () => _sendKey('_'), colorScheme),
                  _buildDivider(colorScheme),
                ],
                // ── End actions ────────────────────────────────────────────
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildIconKey(IconData icon, VoidCallback onTap, ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Icon(icon, size: 18, color: colorScheme.onSurface),
          ),
        ),
      ),
    );
  }

  Widget _buildKey(String label, VoidCallback onTap, ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            constraints: const BoxConstraints(minWidth: 40, minHeight: 36),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: colorScheme.onSurface,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildToggleKey(String label, bool active, VoidCallback onTap, ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: active ? colorScheme.primary : colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            constraints: const BoxConstraints(minWidth: 44, minHeight: 36),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: active ? colorScheme.onPrimary : colorScheme.onSurface,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDivider(ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Container(
        width: 1,
        height: 24,
        color: colorScheme.outlineVariant,
      ),
    );
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.isNotEmpty) {
      _sendRaw(utf8.encode(data.text!));
    }
  }

  void _copySelection() {
    final selection = _terminalController.selection;
    if (selection != null) {
      final text = _terminal.buffer.getText(selection);
      if (text.isNotEmpty) {
        Clipboard.setData(ClipboardData(text: text));
        _terminalController.clearSelection();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Copied to clipboard'),
            duration: Duration(seconds: 1),
          ),
        );
      }
    }
  }

  void _showContextMenu() {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.content_paste),
              title: const Text('Paste'),
              onTap: () {
                Navigator.pop(context);
                _pasteFromClipboard();
              },
            ),
            ListTile(
              leading: const Icon(Icons.content_copy),
              title: const Text('Copy Selection'),
              onTap: () {
                Navigator.pop(context);
                _copySelection();
              },
            ),
            ListTile(
              leading: const Icon(Icons.cleaning_services),
              title: const Text('Clear Terminal'),
              onTap: () {
                Navigator.pop(context);
                _terminal.buffer.clear();
              },
            ),
            ListTile(
              leading: const Icon(Icons.text_fields),
              title: Text('Font Size: ${_fontSize.toStringAsFixed(1)}'),
              onTap: () {
                Navigator.pop(context);
                _showFontSizeDialog();
              },
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('Session Info'),
              onTap: () {
                Navigator.pop(context);
                _showSessionInfo();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showFontSizeDialog() {
    double tempSize = _fontSize;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Font Size'),
        content: StatefulBuilder(
          builder: (context, setDialogState) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(tempSize.toStringAsFixed(1)),
              Slider(
                value: tempSize,
                min: 8,
                max: 24,
                divisions: 16,
                label: tempSize.toStringAsFixed(1),
                onChanged: (v) => setDialogState(() => tempSize = v),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              setState(() => _fontSize = tempSize);
              Navigator.pop(context);
            },
            child: const Text('Apply'),
          ),
        ],
      ),
    );
  }

  void _showSessionInfo() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Session Information'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildInfoRow('Host', widget.session.credential.host),
            _buildInfoRow('Port', widget.session.credential.port.toString()),
            _buildInfoRow('Username', widget.session.credential.username),
            _buildInfoRow('Duration', _formatDuration(widget.session.duration)),
            _buildInfoRow('Status', widget.session.isConnected ? 'Connected' : 'Disconnected'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          Text(value),
        ],
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);

    if (hours > 0) {
      return '${hours}h ${minutes}m ${seconds}s';
    } else if (minutes > 0) {
      return '${minutes}m ${seconds}s';
    } else {
      return '${seconds}s';
    }
  }
}
