import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';

import '../../core/providers/providers.dart';
import '../../data/models/ssh_credential.dart';
import '../../core/services/persistent_ssh_service.dart';
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
                    MaterialPageRoute(builder: (_) => const SshSessionsScreen()),
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
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showAddCredentialDialog(),
        child: const Icon(Icons.add),
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
              style: TextStyle(fontSize: 16, color: colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
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
    final sshService = PersistentSshService();

    // Check if there's already an active session for this credential
    final existingSessions = sshService.getAllSessions();
    final existingSession = existingSessions.where(
      (s) => s.credential.uuid == credential.uuid
    ).firstOrNull;

    final session = existingSession ?? await sshService.createSession(
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
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
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
            content: Text('${widget.credential.host}:${widget.credential.port} reachable (${stopwatch.elapsedMilliseconds}ms)'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${widget.credential.host}:${widget.credential.port} unreachable'),
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
    return ListTile(
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
      subtitle: Text('${widget.credential.username}@${widget.credential.host}:${widget.credential.port}'),
      trailing: PopupMenuButton<String>(
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
      onTap: widget.onTap,
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
  ConsumerState<_SshCredentialDialog> createState() => _SshCredentialDialogState();
}

class _SshCredentialDialogState extends ConsumerState<_SshCredentialDialog> {
  late final TextEditingController _labelController;
  late final TextEditingController _hostController;
  late final TextEditingController _portController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;
  late final TextEditingController _privateKeyController;
  late final TextEditingController _passphraseController;
  late SshAuthType _authType;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _labelController = TextEditingController(text: widget.credential?.label ?? '');
    _hostController = TextEditingController(text: widget.credential?.host ?? '');
    _portController = TextEditingController(text: (widget.credential?.port ?? 22).toString());
    _usernameController = TextEditingController(text: widget.credential?.username ?? '');
    _passwordController = TextEditingController(text: widget.credential?.password ?? '');
    _privateKeyController = TextEditingController(text: widget.credential?.privateKey ?? '');
    _passphraseController = TextEditingController(text: widget.credential?.passphrase ?? '');
    _authType = widget.credential?.authType ?? SshAuthType.password;
  }

  @override
  void dispose() {
    _labelController.dispose();
    _hostController.dispose();
    _portController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _privateKeyController.dispose();
    _passphraseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.credential != null;

    return AlertDialog(
      title: Text(isEditing ? 'Edit SSH Credential' : 'Add SSH Credential'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _labelController,
              decoration: const InputDecoration(
                labelText: 'Label',
                hintText: 'e.g., My Server',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.label),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _hostController,
              decoration: const InputDecoration(
                labelText: 'Host',
                hintText: 'e.g., 192.168.1.100',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.dns),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _portController,
              decoration: const InputDecoration(
                labelText: 'Port',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.numbers),
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _usernameController,
              decoration: const InputDecoration(
                labelText: 'Username',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.person),
              ),
            ),
            const SizedBox(height: 12),
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
              onSelectionChanged: (value) {
                setState(() => _authType = value.first);
              },
            ),
            const SizedBox(height: 12),
            if (_authType == SshAuthType.password)
              TextField(
                controller: _passwordController,
                decoration: const InputDecoration(
                  labelText: 'Password',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.lock),
                ),
                obscureText: true,
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
                    onPressed: _pickKeyFile,
                    icon: const Icon(Icons.file_open, size: 18),
                    label: const Text('Pick File'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _privateKeyController,
                decoration: const InputDecoration(
                  labelText: 'Or paste private key',
                  hintText: '-----BEGIN OPENSSH PRIVATE KEY-----',
                  border: OutlineInputBorder(),
                ),
                maxLines: 4,
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _passphraseController,
                decoration: const InputDecoration(
                  labelText: 'Passphrase (optional)',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.lock),
                ),
                obscureText: true,
              ),
            ],
          ],
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
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
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
    if (_labelController.text.trim().isEmpty ||
        _hostController.text.trim().isEmpty ||
        _usernameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill in Label, Host, and Username')),
      );
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
