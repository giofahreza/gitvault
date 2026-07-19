import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';

import '../../core/providers/providers.dart';
import '../../core/services/ssh_platform/ssh_platform_support.dart';
import '../../data/models/ssh_credential.dart';
import '../../core/services/persistent_ssh_service.dart';
import '../../utils/pointer_focus.dart';
import 'ssh_persistent_terminal_screen.dart';
import 'ssh_sessions_screen.dart';

/// SSH credentials list screen
class SshScreen extends ConsumerStatefulWidget {
  const SshScreen({super.key});

  @override
  ConsumerState<SshScreen> createState() => _SshScreenState();
}

class _SshScreenState extends ConsumerState<SshScreen> {
  @override
  Widget build(BuildContext context) {
    final credentialsAsync = ref.watch(sshCredentialsProvider);
    final sshService = PersistentSshService();

    return Scaffold(
      appBar: AppBar(
        title: const Text('SSH'),
        actions: [
          Stack(
            children: [
              IconButton(
                icon: const Icon(Icons.list_alt),
                tooltip: 'Active Sessions',
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => const SshSessionsScreen()),
                  );
                },
              ),
              if (sshService.hasActiveSessions)
                Positioned(
                  right: 8,
                  top: 8,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(
                      color: Colors.red,
                      shape: BoxShape.circle,
                    ),
                    constraints: const BoxConstraints(
                      minWidth: 16,
                      minHeight: 16,
                    ),
                    child: Text(
                      '${sshService.activeSessionCount}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
      body: credentialsAsync.when(
        data: (credentials) => _buildList(credentials),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => Center(child: Text('Error: $err')),
      ),
      floatingActionButton: Semantics(
        label: 'Add SSH credential',
        button: true,
        child: FloatingActionButton(
          tooltip: 'Add SSH credential',
          onPressed: () => _showAddCredentialDialog(),
          child: const Icon(Icons.add),
        ),
      ),
    );
  }

  Widget _buildList(List<SshCredential> credentials) {
    if (credentials.isEmpty) {
      final colorScheme = Theme.of(context).colorScheme;
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.terminal, size: 64, color: colorScheme.outline),
            const SizedBox(height: 16),
            Text(
              'No SSH credentials yet.\nTap + to add one.',
              textAlign: TextAlign.center,
              style:
                  TextStyle(fontSize: 16, color: colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 96),
      itemCount: credentials.length,
      itemBuilder: (context, index) {
        final credential = credentials[index];
        return _SshCredentialTile(
          credential: credential,
          onTap: () => _connectSsh(credential),
          onEdit: () => _showEditCredentialDialog(credential),
          onDelete: () => _deleteCredential(credential),
        );
      },
    );
  }

  Future<void> _connectSsh(SshCredential credential) async {
    final unsupportedReason = _sshUnsupportedReason();
    if (unsupportedReason != null) {
      if (mounted) {
        _showSshUnavailableDialog(
          context,
          title: 'SSH Unavailable on Web',
          message: unsupportedReason,
        );
      }
      return;
    }

    final sshService = PersistentSshService();

    // Check if there's already an active session for this credential
    final existingSessions = sshService.getAllSessions();
    final existingSession = existingSessions
        .where((s) => s.credential.uuid == credential.uuid)
        .firstOrNull;

    try {
      final session = existingSession ??
          await sshService.createSession(
            credential: credential,
            persistent: true,
          );

      if (mounted) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => SshPersistentTerminalScreen(session: session),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('SSH connection failed: $e'),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  void _showAddCredentialDialog() {
    showDialog(
      context: context,
      builder: (context) => _SshCredentialDialog(
        onSaved: () {
          ref.invalidate(sshCredentialsProvider);
        },
      ),
    );
  }

  void _showEditCredentialDialog(SshCredential credential) {
    showDialog(
      context: context,
      builder: (context) => _SshCredentialDialog(
        credential: credential,
        onSaved: () {
          ref.invalidate(sshCredentialsProvider);
        },
      ),
    );
  }

  Future<void> _deleteCredential(SshCredential credential) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete SSH Credential'),
        content: Text('Delete "${credential.label}"? This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      final repo = ref.read(sshRepositoryProvider);
      await repo.initialize();
      await repo.deleteCredential(credential.uuid);
      ref.invalidate(sshCredentialsProvider);
    }
  }
}

String? _sshUnsupportedReason() {
  if (kIsWeb) {
    return 'Direct SSH and ping require raw TCP sockets, which browsers do not provide. Use the Android app, or connect through an SSH-over-WebSocket proxy.';
  }
  return sshTransportUnsupportedReason();
}

void _showSshUnavailableDialog(
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

class _SshCredentialTile extends StatefulWidget {
  final SshCredential credential;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _SshCredentialTile({
    required this.credential,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  State<_SshCredentialTile> createState() => _SshCredentialTileState();
}

class _SshCredentialTileState extends State<_SshCredentialTile> {
  bool _pinging = false;

  Future<void> _pingHost() async {
    final unsupportedReason = _sshUnsupportedReason();
    if (unsupportedReason != null) {
      _showSshUnavailableDialog(
        context,
        title: 'Ping Unavailable on Web',
        message: unsupportedReason,
      );
      return;
    }

    setState(() => _pinging = true);

    try {
      final stopwatch = Stopwatch()..start();
      final socket = await Socket.connect(
        widget.credential.host,
        widget.credential.port,
        timeout: const Duration(seconds: 5),
      );
      stopwatch.stop();
      socket.destroy();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                '${widget.credential.host}:${widget.credential.port} reachable (${stopwatch.elapsedMilliseconds}ms)'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                '${widget.credential.host}:${widget.credential.port} unreachable'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _pinging = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final compact = MediaQuery.sizeOf(context).width < 520;
    final connectButton = FilledButton.tonalIcon(
      style: FilledButton.styleFrom(
        minimumSize: Size(compact ? 94 : 116, 40),
        padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 16),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onPressed: widget.onTap,
      icon: const Icon(Icons.play_arrow, size: 18),
      label: const Text('Connect'),
    );

    return Semantics(
      container: true,
      button: true,
      label:
          'SSH credential ${widget.credential.label}, ${widget.credential.username} at ${widget.credential.host} port ${widget.credential.port}',
      onTap: widget.onTap,
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: colorScheme.primaryContainer,
          child: _pinging
              ? SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: colorScheme.onPrimaryContainer,
                  ),
                )
              : Icon(Icons.terminal, color: colorScheme.onPrimaryContainer),
        ),
        title: Text(widget.credential.label),
        subtitle: Text(
            '${widget.credential.username}@${widget.credential.host}:${widget.credential.port}'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            connectButton,
            PopupMenuButton<String>(
              tooltip: 'SSH actions',
              onSelected: (value) {
                switch (value) {
                  case 'ping':
                    _pingHost();
                    break;
                  case 'edit':
                    widget.onEdit();
                    break;
                  case 'delete':
                    widget.onDelete();
                    break;
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'ping',
                  child: ListTile(
                    leading: Icon(Icons.network_ping),
                    title: Text('Ping'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                const PopupMenuItem(
                  value: 'edit',
                  child: ListTile(
                    leading: Icon(Icons.edit),
                    title: Text('Edit'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                const PopupMenuItem(
                  value: 'delete',
                  child: ListTile(
                    leading: Icon(Icons.delete, color: Colors.red),
                    title: Text('Delete', style: TextStyle(color: Colors.red)),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
          ],
        ),
        onTap: widget.onTap,
      ),
    );
  }
}

/// Dialog for adding/editing SSH credentials
class _SshCredentialDialog extends ConsumerStatefulWidget {
  final SshCredential? credential;
  final VoidCallback onSaved;

  const _SshCredentialDialog({
    this.credential,
    required this.onSaved,
  });

  @override
  ConsumerState<_SshCredentialDialog> createState() =>
      _SshCredentialDialogState();
}

class _SshCredentialDialogState extends ConsumerState<_SshCredentialDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _labelController;
  late final TextEditingController _hostController;
  late final TextEditingController _portController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;
  late final TextEditingController _privateKeyController;
  late final TextEditingController _passphraseController;
  final _labelFocus = FocusNode();
  final _hostFocus = FocusNode();
  final _portFocus = FocusNode();
  final _usernameFocus = FocusNode();
  final _passwordFocus = FocusNode();
  final _privateKeyFocus = FocusNode();
  final _passphraseFocus = FocusNode();
  late SshAuthType _authType;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _labelController =
        TextEditingController(text: widget.credential?.label ?? '');
    _hostController =
        TextEditingController(text: widget.credential?.host ?? '');
    _portController =
        TextEditingController(text: (widget.credential?.port ?? 22).toString());
    _usernameController =
        TextEditingController(text: widget.credential?.username ?? '');
    _passwordController =
        TextEditingController(text: widget.credential?.password ?? '');
    _privateKeyController =
        TextEditingController(text: widget.credential?.privateKey ?? '');
    _passphraseController =
        TextEditingController(text: widget.credential?.passphrase ?? '');
    _authType = widget.credential?.authType ?? SshAuthType.password;
    _portFocus.addListener(_selectPortOnFocus);
  }

  @override
  void dispose() {
    _portFocus.removeListener(_selectPortOnFocus);
    _labelController.clear();
    _hostController.clear();
    _portController.clear();
    _usernameController.clear();
    _passwordController.clear();
    _privateKeyController.clear();
    _passphraseController.clear();
    _labelController.dispose();
    _hostController.dispose();
    _portController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _privateKeyController.dispose();
    _passphraseController.dispose();
    _labelFocus.dispose();
    _hostFocus.dispose();
    _portFocus.dispose();
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    _privateKeyFocus.dispose();
    _passphraseFocus.dispose();
    super.dispose();
  }

  void _selectPortOnFocus() {
    if (!_portFocus.hasFocus) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_portFocus.hasFocus) return;
      _portController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _portController.text.length,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.credential != null;

    return AlertDialog(
      title: Text(isEditing ? 'Edit SSH Credential' : 'Add SSH Credential'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SegmentedButton<SshAuthType>(
                segments: const [
                  ButtonSegment(
                    value: SshAuthType.password,
                    label: Text('Password'),
                    icon: Icon(Icons.password),
                  ),
                  ButtonSegment(
                    value: SshAuthType.publicKey,
                    label: Text('Key'),
                    icon: Icon(Icons.vpn_key),
                  ),
                ],
                selected: {_authType},
                onSelectionChanged: _saving
                    ? null
                    : (value) {
                        setState(() => _authType = value.first);
                      },
              ),
              const SizedBox(height: 12),
              PointerFocus(
                focusNode: _labelFocus,
                child: TextFormField(
                  controller: _labelController,
                  focusNode: _labelFocus,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Label',
                    hintText: 'e.g., My Server',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.label),
                  ),
                  enabled: !_saving,
                  textInputAction: TextInputAction.next,
                  onFieldSubmitted: (_) => _hostFocus.requestFocus(),
                  validator: (value) => value == null || value.trim().isEmpty
                      ? 'Label is required'
                      : null,
                ),
              ),
              const SizedBox(height: 12),
              PointerFocus(
                focusNode: _hostFocus,
                child: TextFormField(
                  controller: _hostController,
                  focusNode: _hostFocus,
                  decoration: const InputDecoration(
                    labelText: 'Host',
                    hintText: 'e.g., 192.168.1.100',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.dns),
                  ),
                  enabled: !_saving,
                  textInputAction: TextInputAction.next,
                  onFieldSubmitted: (_) => _portFocus.requestFocus(),
                  validator: (value) => value == null || value.trim().isEmpty
                      ? 'Host is required'
                      : null,
                ),
              ),
              const SizedBox(height: 12),
              PointerFocus(
                focusNode: _portFocus,
                child: TextFormField(
                    controller: _portController,
                    focusNode: _portFocus,
                    decoration: const InputDecoration(
                      labelText: 'Port',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.numbers),
                    ),
                    enabled: !_saving,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    textInputAction: TextInputAction.next,
                    onFieldSubmitted: (_) => _usernameFocus.requestFocus(),
                    validator: (value) {
                      final port = int.tryParse(value?.trim() ?? '');
                      if (port == null) return 'Port must be a number';
                      if (port < 1 || port > 65535) {
                        return 'Port must be between 1 and 65535';
                      }
                      return null;
                    }),
              ),
              const SizedBox(height: 12),
              PointerFocus(
                focusNode: _usernameFocus,
                child: TextFormField(
                  controller: _usernameController,
                  focusNode: _usernameFocus,
                  decoration: const InputDecoration(
                    labelText: 'Username',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.person),
                  ),
                  enabled: !_saving,
                  textInputAction: TextInputAction.next,
                  onFieldSubmitted: (_) => _authType == SshAuthType.password
                      ? _passwordFocus.requestFocus()
                      : _privateKeyFocus.requestFocus(),
                  validator: (value) => value == null || value.trim().isEmpty
                      ? 'Username is required'
                      : null,
                ),
              ),
              const SizedBox(height: 12),
              if (_authType == SshAuthType.password)
                PointerFocus(
                  focusNode: _passwordFocus,
                  child: TextFormField(
                    controller: _passwordController,
                    focusNode: _passwordFocus,
                    decoration: const InputDecoration(
                      labelText: 'Password',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.lock),
                    ),
                    enabled: !_saving,
                    obscureText: true,
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) => _save(),
                    validator: (value) => value == null || value.isEmpty
                        ? 'Password is required'
                        : null,
                  ),
                )
              else ...[
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _privateKeyController.text.isEmpty
                            ? 'No private key loaded'
                            : 'Private key loaded (${_privateKeyController.text.length} chars)',
                        style: TextStyle(
                          color: _privateKeyController.text.isEmpty
                              ? Theme.of(context).colorScheme.onSurfaceVariant
                              : Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonalIcon(
                      onPressed: _saving ? null : _pickKeyFile,
                      icon: const Icon(Icons.file_open, size: 18),
                      label: const Text('Pick File'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                PointerFocus(
                  focusNode: _privateKeyFocus,
                  child: TextFormField(
                    controller: _privateKeyController,
                    focusNode: _privateKeyFocus,
                    decoration: const InputDecoration(
                      labelText: 'Or paste private key',
                      hintText: '-----BEGIN OPENSSH PRIVATE KEY-----',
                      border: OutlineInputBorder(),
                    ),
                    enabled: !_saving,
                    maxLines: 4,
                    style:
                        const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                    textInputAction: TextInputAction.next,
                    onFieldSubmitted: (_) => _passphraseFocus.requestFocus(),
                    validator: (value) => value == null || value.trim().isEmpty
                        ? 'Private key is required'
                        : null,
                  ),
                ),
                const SizedBox(height: 12),
                PointerFocus(
                  focusNode: _passphraseFocus,
                  child: TextFormField(
                    controller: _passphraseController,
                    focusNode: _passphraseFocus,
                    decoration: const InputDecoration(
                      labelText: 'Passphrase (optional)',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.lock),
                    ),
                    enabled: !_saving,
                    obscureText: true,
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) => _save(),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : Text(isEditing ? 'Save' : 'Add'),
        ),
      ],
    );
  }

  Future<void> _pickKeyFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
      );

      if (result != null && result.files.single.path != null) {
        final file = File(result.files.single.path!);
        final content = await file.readAsString();
        setState(() {
          _privateKeyController.text = content;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to read key file: $e')),
        );
      }
    }
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }

    setState(() => _saving = true);

    try {
      final repo = ref.read(sshRepositoryProvider);
      await repo.initialize();

      final port = int.tryParse(_portController.text.trim()) ?? 22;

      if (widget.credential != null) {
        final updated = widget.credential!.copyWith(
          label: _labelController.text.trim(),
          host: _hostController.text.trim(),
          port: port,
          username: _usernameController.text.trim(),
          authType: _authType,
          password: _passwordController.text,
          privateKey: _privateKeyController.text,
          passphrase: _passphraseController.text,
        );
        await repo.updateCredential(updated);
      } else {
        await repo.createCredential(
          label: _labelController.text.trim(),
          host: _hostController.text.trim(),
          port: port,
          username: _usernameController.text.trim(),
          authType: _authType,
          password: _passwordController.text,
          privateKey: _privateKeyController.text,
          passphrase: _passphraseController.text,
        );
      }

      widget.onSaved();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save: $e')),
        );
      }
    }
  }
}
