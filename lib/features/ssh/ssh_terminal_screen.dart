import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../../core/services/ssh_connection_manager.dart';
import '../../data/models/ssh_credential.dart';

/// SSH terminal screen using dartssh2 + xterm
class SshTerminalScreen extends StatefulWidget {
  final SshCredential credential;

  const SshTerminalScreen({super.key, required this.credential});

  @override
  State<SshTerminalScreen> createState() => _SshTerminalScreenState();
}

class _SshTerminalScreenState extends State<SshTerminalScreen> {
  late final Terminal _terminal;
  late final TerminalController _terminalController;
  late final FocusNode _focusNode;
  late final TextEditingController _voiceInputController;
  late final SshConnectionManager _connectionManager;
  bool _isConnecting = true;
  bool _isConnected = false;
  StreamSubscription? _stdoutSubscription;
  StreamSubscription? _stderrSubscription;

  // Modifier key toggle states
  bool _ctrlActive = false;
  bool _altActive = false;

  @override
  void initState() {
    super.initState();
    _terminal = Terminal(maxLines: 10000);
    _terminalController = TerminalController();
    _focusNode = FocusNode();
    _voiceInputController = TextEditingController();
    _connectionManager = SshConnectionManager(credential: widget.credential);
    // Listen for voice input and send to terminal
    _voiceInputController.addListener(_handleVoiceInput);
    _connect();
  }

  @override
  void dispose() {
    _stdoutSubscription?.cancel();
    _stderrSubscription?.cancel();
    _terminalController.dispose();
    _focusNode.dispose();
    _voiceInputController.dispose();
    _connectionManager.disconnect();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Reconnect when app resumes
      _reconnect();
    }
  }

  Future<void> _connect() async {
    setState(() {
      _isConnecting = true;
      _isConnected = false;
    });

    _terminal.write('Connecting to ${widget.credential.host}:${widget.credential.port}...\r\n');

    try {
      await _connectionManager.connect();

      _terminal.write('Connected!\r\n');

      final session = _connectionManager.session!;

      // Pipe terminal output with proper UTF-8 decoding
      _stdoutSubscription?.cancel();
      _stdoutSubscription = utf8.decoder.bind(session.stdout).listen((data) {
        _terminal.write(data);
      });

      _stderrSubscription?.cancel();
      _stderrSubscription = utf8.decoder.bind(session.stderr).listen((data) {
        _terminal.write(data);
      });

      // Pipe terminal input, applying modifier keys from toolbar
      _terminal.onOutput = (data) {
        if (_ctrlActive) {
          // Apply Ctrl to each character typed from soft keyboard
          final bytes = <int>[];
          for (final char in data.codeUnits) {
            if (char >= 97 && char <= 122) {
              // a-z -> Ctrl+A-Z (0x01-0x1A)
              bytes.add(char - 96);
            } else if (char >= 65 && char <= 90) {
              // A-Z -> Ctrl+A-Z (0x01-0x1A)
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
          // Alt+key: send ESC prefix before each character
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

      if (mounted) {
        setState(() {
          _isConnecting = false;
          _isConnected = true;
        });
      }
    } catch (e) {
      if (mounted) {
        _terminal.write('\r\nConnection failed: $e\r\n');
        setState(() {
          _isConnecting = false;
          _isConnected = false;
        });
      }
    }
  }

  Future<void> _reconnect() async {
    if (!mounted) return;

    try {
      await _connectionManager.ensureConnected();
      if (mounted && !_isConnected) {
        _terminal.write('\r\nReconnecting...\r\n');
        await _connect();
      }
    } catch (e) {
      if (mounted) {
        _terminal.write('\r\nReconnection failed: $e\r\n');
      }
    }
  }

  /// Send a raw byte sequence to the SSH session
  void _sendRaw(List<int> bytes) {
    _connectionManager.session?.write(Uint8List.fromList(bytes));
  }

  /// Send a key with current modifier state, then reset modifiers
  void _sendKey(String key) {
    if (_ctrlActive) {
      // Ctrl+key: send as control character (key code - 64 for uppercase)
      final code = key.toUpperCase().codeUnitAt(0);
      if (code >= 65 && code <= 90) {
        _sendRaw([code - 64]); // Ctrl+A = 0x01, Ctrl+C = 0x03, etc.
      }
      setState(() => _ctrlActive = false);
      return;
    }

    if (_altActive) {
      // Alt+key: send ESC followed by the key
      _sendRaw([0x1B, ...utf8.encode(key)]);
      setState(() => _altActive = false);
      return;
    }

    _sendRaw(utf8.encode(key));
  }

  /// Handle voice input from Google Keyboard
  void _handleVoiceInput() {
    final text = _voiceInputController.text;
    if (text.isNotEmpty && _isConnected) {
      // Send the voice input text followed by newline
      _sendRaw([...utf8.encode(text), 0x0A]); // 0x0A is Enter
      _voiceInputController.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return WillPopScope(
      onWillPop: () async {
        Navigator.pop(context);
        return false;
      },
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          toolbarHeight: 40,
          title: Row(
            children: [
              if (_isConnecting)
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else if (_isConnected)
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: Icon(Icons.circle, color: Colors.green, size: 10),
                )
              else
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Reconnect',
                  onPressed: _connect,
                  iconSize: 18,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.credential.label,
                  style: const TextStyle(fontSize: 13),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
                iconSize: 18,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
        ),
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Column(
              children: [
                // Terminal view (takes full remaining space)
                Expanded(
                  child: GestureDetector(
                    onTap: () => _focusNode.requestFocus(),
                    child: TerminalView(
                      _terminal,
                      controller: _terminalController,
                      textStyle: const TerminalStyle(
                        fontSize: 11,
                        fontFamily: 'JetBrainsMonoNerd',
                      ),
                    ),
                  ),
                ),
                // Custom keyboard toolbar (only when connected)
                if (_isConnected) _buildKeyboardToolbar(colorScheme),
              ],
            ),
            // Hidden text field for voice input capture
            Positioned(
              top: -1000,
              left: -1000,
              child: TextField(
                focusNode: _focusNode,
                controller: _voiceInputController,
                autofocus: _isConnected,
                autocorrect: false,
                enableSuggestions: false,
              ),
            ),
          ],
        ),
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
              // Copy & Paste
              _buildKey('Paste', () async {
                final data = await Clipboard.getData(Clipboard.kTextPlain);
                if (data?.text != null && data!.text!.isNotEmpty) {
                  _sendRaw(utf8.encode(data.text!));
                }
              }, colorScheme),
              _buildKey('Copy', () {
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
              }, colorScheme),

              _buildDivider(colorScheme),

              // Modifier keys (toggle)
              _buildToggleKey('Ctrl', _ctrlActive, () {
                setState(() => _ctrlActive = !_ctrlActive);
              }, colorScheme),
              _buildToggleKey('Alt', _altActive, () {
                setState(() => _altActive = !_altActive);
              }, colorScheme),

              _buildDivider(colorScheme),

              // Escape & Tab
              _buildKey('Esc', () => _sendRaw([0x1B]), colorScheme),
              _buildKey('Tab', () => _sendRaw([0x09]), colorScheme),

              _buildDivider(colorScheme),

              // Arrow keys
              _buildKey('\u2191', () => _sendRaw([0x1B, 0x5B, 0x41]), colorScheme), // Up
              _buildKey('\u2193', () => _sendRaw([0x1B, 0x5B, 0x42]), colorScheme), // Down
              _buildKey('\u2190', () => _sendRaw([0x1B, 0x5B, 0x44]), colorScheme), // Left
              _buildKey('\u2192', () => _sendRaw([0x1B, 0x5B, 0x43]), colorScheme), // Right

              _buildDivider(colorScheme),

              // Common shortcuts
              _buildKey('Home', () => _sendRaw([0x1B, 0x5B, 0x48]), colorScheme),
              _buildKey('End', () => _sendRaw([0x1B, 0x5B, 0x46]), colorScheme),
              _buildKey('PgUp', () => _sendRaw([0x1B, 0x5B, 0x35, 0x7E]), colorScheme),
              _buildKey('PgDn', () => _sendRaw([0x1B, 0x5B, 0x36, 0x7E]), colorScheme),

              _buildDivider(colorScheme),

              // Common symbols hard to reach on mobile
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
}
