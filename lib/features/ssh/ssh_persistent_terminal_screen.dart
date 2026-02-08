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
  late final FocusNode _focusNode;
  late final TextEditingController _voiceInputController;

  StreamSubscription? _stdoutSubscription;
  StreamSubscription? _stderrSubscription;

  // Modifier key states
  bool _ctrlActive = false;
  bool _altActive = false;

  // Terminal settings
  double _fontSize = 12.0;
  bool _showKeyboard = true;

  // Gesture detection
  static const _volumeKeyChannel = MethodChannel('com.giofahreza.gitvault/volume_keys');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _terminal = Terminal(maxLines: 10000);
    _terminalController = TerminalController();
    _focusNode = FocusNode();
    _voiceInputController = TextEditingController();
    _voiceInputController.addListener(_handleVoiceInput);

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
    _focusNode.dispose();
    _voiceInputController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Reconnect if needed
      if (!widget.session.isConnected) {
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
    if (!widget.session.isConnected) {
      _terminal.write('Reconnecting to ${widget.session.credential.host}...\r\n');
      try {
        await widget.session.reconnect();
      } catch (e) {
        _terminal.write('\r\nConnection failed: $e\r\n');
        return;
      }
    } else {
      _terminal.write('Connected to ${widget.session.credential.host}\r\n');
    }

    final session = widget.session.connectionManager.session!;

    // Pipe terminal output
    _stdoutSubscription?.cancel();
    _stdoutSubscription = utf8.decoder.bind(session.stdout).listen((data) {
      _terminal.write(data);
    });

    _stderrSubscription?.cancel();
    _stderrSubscription = utf8.decoder.bind(session.stderr).listen((data) {
      _terminal.write(data);
    });

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

  void _handleVoiceInput() {
    final text = _voiceInputController.text;
    if (text.isNotEmpty && widget.session.isConnected) {
      _sendRaw([...utf8.encode(text), 0x0A]);
      _voiceInputController.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        // Show warning if session is active
        if (widget.session.isConnected && widget.session.persistent) {
          final leave = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Leave Session'),
              content: const Text(
                'Session will continue running in the background.\n\n'
                'You can access it from the Sessions screen.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Leave'),
                ),
              ],
            ),
          );
          return leave ?? false;
        }
        return true;
      },
      child: Scaffold(
        appBar: _buildAppBar(),
        backgroundColor: Colors.black,
        body: GestureDetector(
          // Double tap to toggle keyboard
          onDoubleTap: () {
            setState(() => _showKeyboard = !_showKeyboard);
          },
          // Long press for context menu
          onLongPress: _showContextMenu,
          child: Stack(
            children: [
              Column(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () => _focusNode.requestFocus(),
                      // Pinch to zoom font size
                      onScaleUpdate: (details) {
                        setState(() {
                          _fontSize = (_fontSize * details.scale).clamp(8.0, 24.0);
                        });
                      },
                      child: TerminalView(
                        _terminal,
                        controller: _terminalController,
                        textStyle: TerminalStyle(
                          fontSize: _fontSize,
                          fontFamily: 'JetBrainsMonoNerd',
                        ),
                      ),
                    ),
                  ),
                  if (_showKeyboard && widget.session.isConnected)
                    _buildKeyboardToolbar(Theme.of(context).colorScheme),
                ],
              ),
              // Hidden text field for voice input
              Positioned(
                top: -1000,
                left: -1000,
                child: TextField(
                  focusNode: _focusNode,
                  controller: _voiceInputController,
                  autofocus: widget.session.isConnected,
                  autocorrect: false,
                  enableSuggestions: false,
                ),
              ),
            ],
          ),
        ),
        drawer: _buildDrawer(),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      toolbarHeight: 40,
      title: Row(
        children: [
          StreamBuilder<SshSessionState>(
            stream: widget.session.stateStream,
            initialData: widget.session.isConnected ? SshSessionState.connected : SshSessionState.disconnected,
            builder: (context, snapshot) {
              final state = snapshot.data ?? SshSessionState.disconnected;

              if (state == SshSessionState.connecting) {
                return const Padding(
                  padding: EdgeInsets.all(8),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                );
              } else if (state == SshSessionState.connected) {
                return const Padding(
                  padding: EdgeInsets.all(8),
                  child: Icon(Icons.circle, color: Colors.green, size: 10),
                );
              } else {
                return IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Reconnect',
                  onPressed: () => widget.session.reconnect(),
                  iconSize: 18,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                );
              }
            },
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              widget.session.credential.label,
              style: const TextStyle(fontSize: 13),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      actions: [
        IconButton(
          icon: Icon(_showKeyboard ? Icons.keyboard_hide : Icons.keyboard),
          tooltip: _showKeyboard ? 'Hide Keyboard' : 'Show Keyboard',
          onPressed: () {
            setState(() => _showKeyboard = !_showKeyboard);
          },
          iconSize: 18,
        ),
        IconButton(
          icon: const Icon(Icons.more_vert),
          onPressed: _showContextMenu,
          iconSize: 18,
        ),
      ],
    );
  }

  Widget _buildDrawer() {
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          DrawerHeader(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.session.credential.label,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '${widget.session.credential.username}@${widget.session.credential.host}',
                  style: TextStyle(
                    fontSize: 14,
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                  ),
                ),
                const Spacer(),
                Text(
                  'Session: ${_formatDuration(widget.session.duration)}',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                  ),
                ),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.text_fields),
            title: Text('Font Size: ${_fontSize.toStringAsFixed(1)}'),
            subtitle: Slider(
              value: _fontSize,
              min: 8,
              max: 24,
              divisions: 16,
              label: _fontSize.toStringAsFixed(1),
              onChanged: (value) {
                setState(() => _fontSize = value);
              },
            ),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.content_paste),
            title: const Text('Paste from Clipboard'),
            onTap: _pasteFromClipboard,
          ),
          ListTile(
            leading: const Icon(Icons.select_all),
            title: const Text('Select All'),
            onTap: () {
              _terminalController.setSelection(
                _terminal.buffer.createAnchor(0, 0),
                _terminal.buffer.createAnchor(
                  _terminal.viewWidth - 1,
                  _terminal.viewHeight - 1,
                ),
              );
              Navigator.pop(context);
            },
          ),
          ListTile(
            leading: const Icon(Icons.cleaning_services),
            title: const Text('Clear Terminal'),
            onTap: () {
              _terminal.buffer.clear();
              Navigator.pop(context);
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('Session Info'),
            onTap: () => _showSessionInfo(),
          ),
        ],
      ),
    );
  }

  Widget _buildKeyboardToolbar(ColorScheme colorScheme) {
    return Container(
      color: colorScheme.surfaceContainerHighest,
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            children: [
              // Paste
              _buildKey('Paste', _pasteFromClipboard, colorScheme),
              _buildKey('Copy', _copySelection, colorScheme),
              _buildDivider(colorScheme),

              // Modifiers
              _buildToggleKey('Ctrl', _ctrlActive, () {
                setState(() => _ctrlActive = !_ctrlActive);
              }, colorScheme),
              _buildToggleKey('Alt', _altActive, () {
                setState(() => _altActive = !_altActive);
              }, colorScheme),
              _buildDivider(colorScheme),

              // Special keys
              _buildKey('Esc', () => _sendRaw([0x1B]), colorScheme),
              _buildKey('Tab', () => _sendRaw([0x09]), colorScheme),
              _buildDivider(colorScheme),

              // Arrows
              _buildKey('↑', () => _sendRaw([0x1B, 0x5B, 0x41]), colorScheme),
              _buildKey('↓', () => _sendRaw([0x1B, 0x5B, 0x42]), colorScheme),
              _buildKey('←', () => _sendRaw([0x1B, 0x5B, 0x44]), colorScheme),
              _buildKey('→', () => _sendRaw([0x1B, 0x5B, 0x43]), colorScheme),
              _buildDivider(colorScheme),

              // Navigation
              _buildKey('Home', () => _sendRaw([0x1B, 0x5B, 0x48]), colorScheme),
              _buildKey('End', () => _sendRaw([0x1B, 0x5B, 0x46]), colorScheme),
              _buildKey('PgUp', () => _sendRaw([0x1B, 0x5B, 0x35, 0x7E]), colorScheme),
              _buildKey('PgDn', () => _sendRaw([0x1B, 0x5B, 0x36, 0x7E]), colorScheme),
              _buildDivider(colorScheme),

              // Symbols
              _buildKey('|', () => _sendKey('|'), colorScheme),
              _buildKey('/', () => _sendKey('/'), colorScheme),
              _buildKey('\\', () => _sendKey('\\'), colorScheme),
              _buildKey('~', () => _sendKey('~'), colorScheme),
              _buildKey('-', () => _sendKey('-'), colorScheme),
              _buildKey('_', () => _sendKey('_'), colorScheme),
            ],
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
