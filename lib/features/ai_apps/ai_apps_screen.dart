import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/widgets/vault_lock_action.dart';
import '../../mcp/mcp_client_registry.dart';
import '../../mcp/mcp_desktop_server.dart';
import '../../mcp/mcp_desktop_server_state.dart';
import '../../mcp/mcp_models.dart';
import '../../mcp/mcp_platform.dart';
import '../../mcp/mcp_providers.dart';

class AiAppsScreen extends ConsumerStatefulWidget {
  const AiAppsScreen({super.key});

  @override
  ConsumerState<AiAppsScreen> createState() => _AiAppsScreenState();
}

class _AiAppsScreenState extends ConsumerState<AiAppsScreen> {
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      await ref.read(mcpClientRegistryProvider).initialize();
      await ref.read(mcpDesktopServerProvider).initialize();
    } catch (error) {
      _error = '$error';
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final registry = ref.watch(mcpClientRegistryProvider);
    final server = ref.watch(mcpDesktopServerProvider);
    final endpoint = server.state.endpoint;

    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Apps'),
        actions: const [VaultLockAction()],
      ),
      floatingActionButton: isDesktopPlatform && registry.enabled
          ? FloatingActionButton.extended(
              onPressed: () => _connectApp(registry, server),
              icon: const Icon(Icons.add),
              label: const Text('Connect app'),
            )
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorState(message: _error!, onRetry: _initialize)
              : !isDesktopPlatform
                  ? const _UnsupportedState()
                  : ListView(
                      padding: const EdgeInsets.only(bottom: 104),
                      children: [
                        const _SectionHeader(title: 'Service'),
                        SwitchListTile(
                          secondary: const Icon(Icons.smart_toy_outlined),
                          title: const Text('Allow AI apps'),
                          subtitle: const Text(
                            'AI apps can access permitted notes only while GitVault Desktop is unlocked',
                          ),
                          value: registry.enabled,
                          onChanged: (value) async {
                            await registry.setEnabled(value);
                            await server.refresh();
                          },
                        ),
                        _ServerStatusTile(state: server.state),
                        if (endpoint != null)
                          ListTile(
                            leading: const Icon(Icons.link),
                            title: const Text('Local endpoint'),
                            subtitle: SelectableText(endpoint.toString()),
                            trailing: IconButton(
                              tooltip: 'Copy local endpoint',
                              onPressed: () => _copy(
                                endpoint.toString(),
                                'Local endpoint copied',
                              ),
                              icon: const Icon(Icons.copy),
                            ),
                          ),
                        if (registry.enabled)
                          ListTile(
                            leading: const Icon(Icons.settings_ethernet),
                            title: const Text('Local server port'),
                            subtitle: Text(
                              server.state.endpoint == null
                                  ? '${registry.port}'
                                  : '${server.state.endpoint!.port}',
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => _editPort(registry, server),
                          ),
                        SwitchListTile(
                          secondary: const Icon(Icons.power_settings_new),
                          title: const Text('Launch at sign-in'),
                          subtitle: const Text(
                            'Start GitVault Desktop when you sign in',
                          ),
                          value: registry.launchAtStartup,
                          onChanged: registry.setLaunchAtStartup,
                        ),
                        SwitchListTile(
                          secondary: const Icon(Icons.move_to_inbox_outlined),
                          title: const Text('Keep running in tray'),
                          subtitle: const Text(
                            'Closing the window keeps connected AI apps available',
                          ),
                          value: registry.keepInTray,
                          onChanged: registry.setKeepInTray,
                        ),
                        const Divider(),
                        _SectionHeader(
                          title: 'Connected apps',
                          action: registry.activeClients.isEmpty
                              ? null
                              : TextButton(
                                  onPressed: () => _revokeAll(registry, server),
                                  child: const Text('Revoke all'),
                                ),
                        ),
                        if (registry.clients.isEmpty)
                          const _EmptyClients()
                        else
                          for (final client in registry.clients)
                            _ClientTile(
                              client: client,
                              onTap: () =>
                                  _editClient(registry, server, client),
                              onAction: (action) => _handleClientAction(
                                action,
                                registry,
                                server,
                                client,
                              ),
                            ),
                        const Divider(),
                        _SectionHeader(
                          title: 'Recent activity',
                          action: registry.activity.isEmpty
                              ? null
                              : TextButton(
                                  onPressed: registry.clearActivity,
                                  child: const Text('Clear'),
                                ),
                        ),
                        if (registry.activity.isEmpty)
                          const Padding(
                            padding: EdgeInsets.fromLTRB(16, 8, 16, 24),
                            child: Text('No AI app activity yet.'),
                          )
                        else
                          for (final record in registry.activity.take(50))
                            _ActivityTile(record: record),
                      ],
                    ),
    );
  }

  Future<void> _connectApp(
    McpClientRegistry registry,
    McpDesktopServer server,
  ) async {
    final draft = await showDialog<_ClientDraft>(
      context: context,
      builder: (_) => const _ClientEditorDialog(),
    );
    if (draft == null) return;
    try {
      final issued = await registry.createClient(
        displayName: draft.name,
        transport: draft.transport,
        permissions: draft.permissions,
        allowedTags: draft.allowedTags,
        deniedTags: draft.deniedTags,
        writePolicy: draft.writePolicy,
      );
      if (draft.transport == McpClientTransport.stdio) {
        await server.writeStdioProfile(
          clientId: issued.client.id,
          token: issued.token,
        );
      }
      if (!mounted) return;
      await _showConfiguration(server, issued);
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _editClient(
    McpClientRegistry registry,
    McpDesktopServer server,
    McpClientRegistration client,
  ) async {
    final draft = await showDialog<_ClientDraft>(
      context: context,
      builder: (_) => _ClientEditorDialog(client: client),
    );
    if (draft == null) return;
    try {
      await registry.updateClient(
        client.id,
        displayName: draft.name,
        permissions: draft.permissions,
        allowedTags: draft.allowedTags,
        deniedTags: draft.deniedTags,
        writePolicy: draft.writePolicy,
      );
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _handleClientAction(
    _ClientAction action,
    McpClientRegistry registry,
    McpDesktopServer server,
    McpClientRegistration client,
  ) async {
    try {
      switch (action) {
        case _ClientAction.copyConfig:
          if (client.transport == McpClientTransport.stdio) {
            await _copy(server.stdioConfig(client.id), 'Configuration copied');
          } else {
            _showError(
              'Rotate the HTTP credential to generate a new configuration.',
            );
          }
          break;
        case _ClientAction.rotate:
          final issued = await registry.rotateCredential(client.id);
          if (client.transport == McpClientTransport.stdio) {
            await server.writeStdioProfile(
              clientId: client.id,
              token: issued.token,
            );
          }
          if (mounted) await _showConfiguration(server, issued);
          break;
        case _ClientAction.revoke:
          await registry.revokeClient(client.id);
          await server.removeStdioProfile(client.id);
          break;
        case _ClientAction.restore:
          final issued = await registry.rotateCredential(client.id);
          if (client.transport == McpClientTransport.stdio) {
            await server.writeStdioProfile(
              clientId: client.id,
              token: issued.token,
            );
          }
          if (mounted) await _showConfiguration(server, issued);
          break;
        case _ClientAction.remove:
          if (!await _confirm(
            title: 'Remove AI app?',
            message:
                '${client.displayName} will lose access and its local profile will be deleted.',
            confirmLabel: 'Remove',
          )) {
            return;
          }
          await registry.removeClient(client.id);
          await server.removeStdioProfile(client.id);
          break;
      }
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _showConfiguration(
    McpDesktopServer server,
    McpIssuedCredential issued,
  ) async {
    final config = issued.client.transport == McpClientTransport.stdio
        ? server.stdioConfig(issued.client.id)
        : server.httpConfig(issued.token);
    final guidance = issued.client.transport ==
            McpClientTransport.streamableHttp
        ? 'Add this configuration to the AI app. The HTTP credential is shown only once; rotate it if you lose this configuration.'
        : 'Add this configuration to the AI app. It uses a local profile managed by GitVault Desktop, so no credential is placed in the command.';
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: Text('${issued.client.displayName} configuration'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(guidance),
              const SizedBox(height: 16),
              Container(
                constraints: const BoxConstraints(maxHeight: 320),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    config,
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () => _copy(config, 'Configuration copied'),
            icon: const Icon(Icons.copy),
            label: const Text('Copy'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  Future<void> _editPort(
    McpClientRegistry registry,
    McpDesktopServer server,
  ) async {
    final controller = TextEditingController(text: '${registry.port}');
    final value = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Local server port'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
            labelText: 'Port',
            helperText: '1024 to 65535',
          ),
          onSubmitted: (value) {
            Navigator.of(dialogContext).pop(int.tryParse(value));
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(
              int.tryParse(controller.text),
            ),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || value == registry.port) return;
    try {
      await registry.setPort(value);
      await server.stop();
      await server.start();
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _revokeAll(
    McpClientRegistry registry,
    McpDesktopServer server,
  ) async {
    if (!await _confirm(
      title: 'Revoke all AI apps?',
      message: 'Every connected AI app will immediately lose access.',
      confirmLabel: 'Revoke all',
    )) {
      return;
    }
    for (final client in registry.activeClients) {
      await server.removeStdioProfile(client.id);
    }
    await registry.revokeAllClients();
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
  }) async {
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(confirmLabel),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _copy(String value, String message) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void _showError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$error')),
    );
  }
}

class _ClientEditorDialog extends StatefulWidget {
  final McpClientRegistration? client;

  const _ClientEditorDialog({this.client});

  @override
  State<_ClientEditorDialog> createState() => _ClientEditorDialogState();
}

class _ClientEditorDialogState extends State<_ClientEditorDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _allowedTagsController;
  late final TextEditingController _deniedTagsController;
  late McpClientTransport _transport;
  late McpWritePolicy _writePolicy;
  late Set<McpPermission> _permissions;
  String? _error;

  @override
  void initState() {
    super.initState();
    final client = widget.client;
    _nameController = TextEditingController(text: client?.displayName ?? '');
    _allowedTagsController =
        TextEditingController(text: client?.allowedTags.join(', ') ?? '');
    _deniedTagsController =
        TextEditingController(text: client?.deniedTags.join(', ') ?? '');
    _transport = client?.transport ?? McpClientTransport.stdio;
    _writePolicy = client?.writePolicy ?? McpWritePolicy.askEveryTime;
    _permissions = Set.of(
      client?.permissions ??
          const {
            McpPermission.readMetadata,
            McpPermission.readContent,
            McpPermission.search,
            McpPermission.create,
            McpPermission.append,
            McpPermission.edit,
            McpPermission.archive,
          },
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _allowedTagsController.dispose();
    _deniedTagsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.client != null;
    return AlertDialog(
      title: Text(editing ? 'Edit AI app' : 'Connect AI app'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 680),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _nameController,
                autofocus: !editing,
                maxLength: 80,
                decoration: const InputDecoration(
                  labelText: 'App name',
                  hintText: 'Desktop AI assistant',
                ),
              ),
              const SizedBox(height: 12),
              SegmentedButton<McpClientTransport>(
                segments: const [
                  ButtonSegment(
                    value: McpClientTransport.stdio,
                    icon: Icon(Icons.terminal),
                    label: Text('stdio'),
                  ),
                  ButtonSegment(
                    value: McpClientTransport.streamableHttp,
                    icon: Icon(Icons.http),
                    label: Text('HTTP'),
                  ),
                ],
                selected: {_transport},
                onSelectionChanged: editing
                    ? null
                    : (selected) => setState(() => _transport = selected.first),
              ),
              const SizedBox(height: 20),
              Text(
                'Permissions',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              for (final permission in McpPermission.values)
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(permission.label),
                  value: _permissions.contains(permission),
                  onChanged: (value) {
                    setState(() {
                      if (value == true) {
                        _permissions.add(permission);
                      } else {
                        _permissions.remove(permission);
                      }
                    });
                  },
                ),
              const SizedBox(height: 12),
              DropdownButtonFormField<McpWritePolicy>(
                value: _writePolicy,
                decoration: const InputDecoration(labelText: 'Write approval'),
                items: [
                  for (final policy in McpWritePolicy.values)
                    DropdownMenuItem(
                      value: policy,
                      child: Text(policy.label),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _writePolicy = value);
                },
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _allowedTagsController,
                decoration: const InputDecoration(
                  labelText: 'Allowed tags',
                  hintText: 'work, projects',
                  helperText: 'Empty means all tags',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _deniedTagsController,
                decoration: const InputDecoration(
                  labelText: 'Denied tags',
                  hintText: 'private, finance',
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(editing ? 'Save' : 'Connect'),
        ),
      ],
    );
  }

  void _submit() {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter a recognizable app name.');
      return;
    }
    Navigator.of(context).pop(
      _ClientDraft(
        name: name,
        transport: _transport,
        permissions: _permissions,
        allowedTags: _tags(_allowedTagsController.text),
        deniedTags: _tags(_deniedTagsController.text),
        writePolicy: _writePolicy,
      ),
    );
  }

  Set<String> _tags(String value) => value
      .split(',')
      .map((tag) => tag.trim().replaceFirst(RegExp(r'^#'), '').toLowerCase())
      .where((tag) => tag.isNotEmpty)
      .toSet();
}

class _ClientDraft {
  final String name;
  final McpClientTransport transport;
  final Set<McpPermission> permissions;
  final Set<String> allowedTags;
  final Set<String> deniedTags;
  final McpWritePolicy writePolicy;

  const _ClientDraft({
    required this.name,
    required this.transport,
    required this.permissions,
    required this.allowedTags,
    required this.deniedTags,
    required this.writePolicy,
  });
}

enum _ClientAction {
  copyConfig,
  rotate,
  revoke,
  restore,
  remove,
}

class _ClientTile extends StatelessWidget {
  final McpClientRegistration client;
  final VoidCallback onTap;
  final ValueChanged<_ClientAction> onAction;

  const _ClientTile({
    required this.client,
    required this.onTap,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final details = client.isActive
        ? '${client.transport.label} · ${client.permissions.length} permissions'
        : 'Revoked · ${client.transport.label}';
    final usage = client.lastUsedAt == null
        ? 'Never used'
        : 'Last used ${_relativeTime(client.lastUsedAt!)}';
    return ListTile(
      leading: Icon(
        client.transport == McpClientTransport.stdio
            ? Icons.terminal
            : Icons.http,
        color: client.isActive
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.outline,
      ),
      title: Text(client.displayName),
      subtitle: Text('$details\n$usage'),
      isThreeLine: true,
      onTap: onTap,
      trailing: PopupMenuButton<_ClientAction>(
        tooltip: 'AI app actions',
        onSelected: onAction,
        itemBuilder: (context) => [
          if (client.transport == McpClientTransport.stdio && client.isActive)
            const PopupMenuItem(
              value: _ClientAction.copyConfig,
              child: Text('Copy configuration'),
            ),
          if (client.isActive)
            const PopupMenuItem(
              value: _ClientAction.rotate,
              child: Text('Rotate credential'),
            ),
          PopupMenuItem(
            value:
                client.isActive ? _ClientAction.revoke : _ClientAction.restore,
            child: Text(client.isActive ? 'Revoke' : 'Restore'),
          ),
          const PopupMenuItem(
            value: _ClientAction.remove,
            child: Text('Remove'),
          ),
        ],
      ),
    );
  }
}

class _ActivityTile extends StatelessWidget {
  final McpActivityRecord record;

  const _ActivityTile({required this.record});

  @override
  Widget build(BuildContext context) {
    final allowed = record.result == McpActivityResult.allowed;
    return ListTile(
      dense: true,
      leading: Icon(
        allowed ? Icons.check_circle_outline : Icons.block,
        color: allowed
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.error,
      ),
      title: Text('${record.clientName} · ${record.action}'),
      subtitle: Text(
        '${_relativeTime(record.timestamp)}'
        '${record.approvalRequested ? ' · approval requested' : ''}',
      ),
      trailing: Text(record.result.name),
    );
  }
}

class _ServerStatusTile extends StatelessWidget {
  final McpDesktopServerState state;

  const _ServerStatusTile({required this.state});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (state.status) {
      McpDesktopServerStatus.ready => (
          'Ready · ${state.activeSessions} active sessions',
          Colors.green
        ),
      McpDesktopServerStatus.locked => ('Locked', Colors.orange),
      McpDesktopServerStatus.starting => ('Starting...', Colors.orange),
      McpDesktopServerStatus.error => (
          state.error ?? 'Server error',
          Theme.of(context).colorScheme.error
        ),
      McpDesktopServerStatus.unsupported => ('Unsupported', Colors.grey),
      McpDesktopServerStatus.stopped => ('Stopped', Colors.grey),
    };
    return ListTile(
      leading: Icon(Icons.circle, size: 12, color: color),
      title: const Text('MCP service'),
      subtitle: Text(label),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final Widget? action;

  const _SectionHeader({
    required this.title,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          if (action != null) action!,
        ],
      ),
    );
  }
}

class _EmptyClients extends StatelessWidget {
  const _EmptyClients();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Text('No AI apps are connected.'),
    );
  }
}

class _UnsupportedState extends StatelessWidget {
  const _UnsupportedState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Text(
          'AI app access is available in GitVault Desktop for Windows, macOS, and Linux.',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorState({
    required this.message,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: onRetry,
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}

String _relativeTime(DateTime value) {
  final difference = DateTime.now().toUtc().difference(value.toUtc());
  if (difference.inMinutes < 1) return 'just now';
  if (difference.inHours < 1) return '${difference.inMinutes}m ago';
  if (difference.inDays < 1) return '${difference.inHours}h ago';
  return '${difference.inDays}d ago';
}
