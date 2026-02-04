import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/providers.dart';
import '../../core/services/github_service.dart';
import '../../data/models/vault_entry.dart';
import '../../data/repositories/sync_engine.dart';
import '../../utils/totp_generator.dart';

/// Main vault screen displaying all password entries grouped by category
class VaultScreen extends ConsumerStatefulWidget {
  const VaultScreen({super.key});

  @override
  ConsumerState<VaultScreen> createState() => _VaultScreenState();
}

class _VaultScreenState extends ConsumerState<VaultScreen> {
  final _searchController = TextEditingController();
  String _searchQuery = '';
  final Set<String> _expandedGroups = {};

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entriesAsync = ref.watch(vaultEntriesProvider);

    return Scaffold(
      appBar: AppBar(
        title: _searchQuery.isEmpty
            ? const Text('Passwords')
            : TextField(
                controller: _searchController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Search passwords...',
                  border: InputBorder.none,
                ),
                style: const TextStyle(fontSize: 18),
                onChanged: (value) => setState(() => _searchQuery = value),
              ),
        actions: [
          if (_searchQuery.isEmpty)
            IconButton(
              icon: const Icon(Icons.search),
              tooltip: 'Search',
              onPressed: () {
                setState(() => _searchQuery = ' ');
                _searchController.clear();
              },
            )
          else
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: () {
                setState(() {
                  _searchQuery = '';
                  _searchController.clear();
                });
              },
            ),
        ],
      ),
      body: entriesAsync.when(
        data: (entries) => _buildVaultList(entries),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => Center(child: Text('Error: $err')),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showAddEntryDialog(),
        child: const Icon(Icons.add),
      ),
    );
  }

  String _getGroup(VaultEntry entry) {
    if (entry.tags.isNotEmpty && entry.tags.first.isNotEmpty) {
      return entry.tags.first;
    }
    return 'Ungrouped';
  }

  Widget _buildVaultList(List<VaultEntry> entries) {
    // Filter out 2FA-only entries (entries with empty passwords)
    final passwordEntries = entries.where((e) => e.password.isNotEmpty).toList();

    final filtered = _searchQuery.isEmpty
        ? passwordEntries
        : passwordEntries.where((e) {
            final q = _searchQuery.toLowerCase();
            return e.title.toLowerCase().contains(q) ||
                e.username.toLowerCase().contains(q) ||
                (e.url?.toLowerCase().contains(q) ?? false) ||
                e.tags.any((t) => t.toLowerCase().contains(q));
          }).toList();

    if (filtered.isEmpty) {
      final colorScheme = Theme.of(context).colorScheme;
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.lock_outline, size: 64, color: colorScheme.outline),
            const SizedBox(height: 16),
            Text(
              _searchQuery.isNotEmpty
                  ? 'No matching entries'
                  : 'No entries yet.\nTap + to add one.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, color: colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }

    // Group entries
    final Map<String, List<VaultEntry>> grouped = {};
    for (final entry in filtered) {
      final group = _getGroup(entry);
      grouped.putIfAbsent(group, () => []).add(entry);
    }

    // Sort groups: "Ungrouped" last, others alphabetically
    final sortedGroups = grouped.keys.toList()
      ..sort((a, b) {
        if (a == 'Ungrouped') return 1;
        if (b == 'Ungrouped') return -1;
        return a.toLowerCase().compareTo(b.toLowerCase());
      });

    // If only one group and it's "Ungrouped", show flat list
    if (sortedGroups.length == 1 && sortedGroups.first == 'Ungrouped') {
      return ListView.builder(
        itemCount: filtered.length,
        itemBuilder: (context, index) {
          final entry = filtered[index];
          return _VaultEntryTile(
            entry: entry,
            onTap: () => _showEntryDetails(entry),
            onCopyPassword: () => _copyPassword(entry),
          );
        },
      );
    }

    return ListView.builder(
      itemCount: sortedGroups.length,
      itemBuilder: (context, index) {
        final group = sortedGroups[index];
        final groupEntries = grouped[group]!;
        final isCollapsed = !_expandedGroups.contains(group);

        return _GroupSection(
          groupName: group,
          entries: groupEntries,
          isCollapsed: isCollapsed,
          onToggle: () {
            setState(() {
              if (isCollapsed) {
                _expandedGroups.add(group);
              } else {
                _expandedGroups.remove(group);
              }
            });
          },
          onEntryTap: _showEntryDetails,
          onCopyPassword: _copyPassword,
        );
      },
    );
  }

  void _copyPassword(VaultEntry entry) {
    Clipboard.setData(ClipboardData(text: entry.password));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Password copied to clipboard'),
        duration: Duration(seconds: 2),
      ),
    );

    // Auto-clear clipboard after configured seconds
    final seconds = ref.read(clipboardClearSecondsProvider);
    Future.delayed(Duration(seconds: seconds), () {
      Clipboard.setData(const ClipboardData(text: ''));
    });
  }

  void _showEntryDetails(VaultEntry entry) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => _EntryDetailsSheet(
        entry: entry,
        onEdit: () {
          Navigator.of(sheetContext).pop();
          _showEditEntryDialog(entry);
        },
        onDelete: () async {
          Navigator.of(sheetContext).pop();
          final confirm = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Delete Entry'),
              content: Text('Are you sure to delete "${entry.title}"?'),
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
            final repo = ref.read(vaultRepositoryProvider);
            await repo.initialize();
            await repo.deleteEntry(entry.uuid);
            ref.invalidate(vaultEntriesProvider);
            // Auto-sync after delete (in background)
            _syncVault().catchError((e) => debugPrint('Auto-sync failed: $e'));
          }
        },
        onCopyPassword: () => _copyPassword(entry),
        onCopyUsername: () {
          Clipboard.setData(ClipboardData(text: entry.username));
          ScaffoldMessenger.of(sheetContext).showSnackBar(
            const SnackBar(content: Text('Username copied'), duration: Duration(seconds: 2)),
          );
        },
      ),
    );
  }

  void _showEditEntryDialog(VaultEntry entry) {
    showDialog(
      context: context,
      builder: (context) => EditEntryDialog(
        entry: entry,
        onSaved: () {
          ref.invalidate(vaultEntriesProvider);
          // Auto-sync after edit (in background)
          _syncVault().catchError((e) => debugPrint('Auto-sync failed: $e'));
        },
      ),
    );
  }

  Future<void> _syncVault() async {
    final keyStorage = ref.read(keyStorageProvider);
    await keyStorage.initialize();
    final hasGitHub = await keyStorage.hasGitHubCredentials();

    if (!hasGitHub) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('GitHub not configured. Set it up in Settings > Backup > GitHub Sync')),
        );
      }
      return;
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Syncing...')),
      );
    }

    try {
      final token = await keyStorage.getGitHubToken();
      final owner = await keyStorage.getRepoOwner();
      final name = await keyStorage.getRepoName();

      if (token == null || owner == null || name == null) {
        throw Exception('GitHub credentials incomplete. Please reconfigure in Settings.');
      }

      final githubService = GitHubService(
        accessToken: token,
        repoOwner: owner,
        repoName: name,
      );

      final syncEngine = SyncEngine(
        vaultRepository: ref.read(vaultRepositoryProvider),
        notesRepository: ref.read(notesRepositoryProvider),
        sshRepository: ref.read(sshRepositoryProvider),
        githubService: githubService,
        cryptoManager: ref.read(cryptoManagerProvider),
        keyStorage: keyStorage,
      );

      await syncEngine.initialize();
      final result = await syncEngine.sync();
      syncEngine.dispose(); // Don't close the box, just dispose resources
      githubService.dispose();

      ref.invalidate(vaultEntriesProvider);

      if (mounted) {
        String message;
        if (result.pushed == 0 && result.pulled == 0) {
          message = 'Synced (up to date)';
        } else {
          message = 'Synced: ${result.pushed} pushed, ${result.pulled} pulled';
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message), backgroundColor: Theme.of(context).colorScheme.tertiary),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Sync failed: $e')),
        );
      }
    }
  }

  void _showAddEntryDialog() {
    showDialog(
      context: context,
      builder: (context) => AddEntryDialog(
        onSaved: () {
          ref.invalidate(vaultEntriesProvider);
          // Auto-sync after create (in background)
          _syncVault().catchError((e) => debugPrint('Auto-sync failed: $e'));
        },
      ),
    );
  }
}

/// Collapsible group section
class _GroupSection extends StatelessWidget {
  final String groupName;
  final List<VaultEntry> entries;
  final bool isCollapsed;
  final VoidCallback onToggle;
  final void Function(VaultEntry) onEntryTap;
  final void Function(VaultEntry) onCopyPassword;

  const _GroupSection({
    required this.groupName,
    required this.entries,
    required this.isCollapsed,
    required this.onToggle,
    required this.onEntryTap,
    required this.onCopyPassword,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Icon(
                  isCollapsed ? Icons.expand_more : Icons.expand_less,
                  size: 20,
                  color: colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Text(
                  groupName,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurfaceVariant,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '(${entries.length})',
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.outline,
                  ),
                ),
                const Spacer(),
              ],
            ),
          ),
        ),
        if (!isCollapsed)
          ...entries.map((entry) => _VaultEntryTile(
                entry: entry,
                onTap: () => onEntryTap(entry),
                onCopyPassword: () => onCopyPassword(entry),
              )),
        const Divider(height: 1),
      ],
    );
  }
}

class _VaultEntryTile extends StatelessWidget {
  final VaultEntry entry;
  final VoidCallback onTap;
  final VoidCallback onCopyPassword;

  const _VaultEntryTile({
    required this.entry,
    required this.onTap,
    required this.onCopyPassword,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: colorScheme.primaryContainer,
        child: Text(
          entry.title.isNotEmpty ? entry.title[0].toUpperCase() : '?',
          style: TextStyle(
            color: colorScheme.onPrimaryContainer,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      title: Text(entry.title),
      subtitle: Text(entry.username),
      trailing: IconButton(
        icon: const Icon(Icons.copy),
        tooltip: 'Copy password',
        onPressed: onCopyPassword,
      ),
      onTap: onTap,
    );
  }
}

class _EntryDetailsSheet extends StatelessWidget {
  final VaultEntry entry;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onCopyPassword;
  final VoidCallback onCopyUsername;

  const _EntryDetailsSheet({
    required this.entry,
    required this.onEdit,
    required this.onDelete,
    required this.onCopyPassword,
    required this.onCopyUsername,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) {
        return Padding(
          padding: const EdgeInsets.all(24),
          child: ListView(
            controller: scrollController,
            children: [
              Center(
                child: Container(
                  width: 40, height: 4,
                  decoration: BoxDecoration(
                    color: colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: Text(entry.title, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.edit),
                    tooltip: 'Edit',
                    onPressed: onEdit,
                  ),
                ],
              ),
              if (entry.tags.isNotEmpty && entry.tags.first.isNotEmpty) ...[
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  children: [
                    Chip(
                      label: Text(entry.tags.first, style: const TextStyle(fontSize: 12)),
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 24),
              _DetailRow(label: 'Username', value: entry.username, onCopy: onCopyUsername),
              const SizedBox(height: 12),
              _DetailRow(label: 'Password', value: entry.password, obscured: true, onCopy: onCopyPassword),
              if (entry.totpSecret != null && entry.totpSecret!.isNotEmpty) ...[
                const SizedBox(height: 12),
                _TotpCodeRow(totpSecret: entry.totpSecret!),
              ],
              if (entry.url != null && entry.url!.isNotEmpty) ...[
                const SizedBox(height: 12),
                _DetailRow(label: 'URL', value: entry.url!),
              ],
              if (entry.notes != null && entry.notes!.isNotEmpty) ...[
                const SizedBox(height: 12),
                _DetailRow(label: 'Notes', value: entry.notes!),
              ],
              const SizedBox(height: 24),
              OutlinedButton.icon(
                onPressed: onDelete,
                icon: Icon(Icons.delete_forever, color: colorScheme.error),
                label: Text('Delete Entry', style: TextStyle(color: colorScheme.error)),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _DetailRow extends ConsumerStatefulWidget {
  final String label;
  final String value;
  final bool obscured;
  final VoidCallback? onCopy;

  const _DetailRow({
    required this.label,
    required this.value,
    this.obscured = false,
    this.onCopy,
  });

  @override
  ConsumerState<_DetailRow> createState() => _DetailRowState();
}

class _DetailRowState extends ConsumerState<_DetailRow> {
  bool _hidden = true;

  Future<void> _togglePasswordVisibility() async {
    if (!_hidden) {
      setState(() => _hidden = true);
      return;
    }

    // Check if biometric or PIN is enabled
    final biometricEnabled = ref.read(biometricEnabledProvider);
    final pinEnabled = await ref.read(pinEnabledProvider.future);

    if (!biometricEnabled && !pinEnabled) {
      // Neither is enabled — prompt user to enable one
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Authentication Required'),
          content: const Text('Please enable biometrics or PIN in Settings to view passwords.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }

    // Try biometric first
    if (biometricEnabled) {
      final biometricAuth = ref.read(biometricAuthProvider);
      final supported = await biometricAuth.isSupported();
      if (supported) {
        final authenticated = await biometricAuth.authenticate(
          reason: 'Authenticate to view password',
        );
        if (authenticated && mounted) {
          setState(() => _hidden = false);
        }
        return;
      }
    }

    // Fall back to PIN
    if (pinEnabled && mounted) {
      final result = await showDialog<bool>(
        context: context,
        builder: (ctx) => _PinVerifyDialog(),
      );
      if (result == true && mounted) {
        setState(() => _hidden = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final displayValue = (widget.obscured && _hidden) ? '••••••••' : widget.value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.label, style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant)),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(child: Text(displayValue, style: const TextStyle(fontSize: 16))),
            if (widget.obscured)
              IconButton(
                icon: Icon(_hidden ? Icons.visibility : Icons.visibility_off, size: 20),
                onPressed: _togglePasswordVisibility,
              ),
            if (widget.onCopy != null)
              IconButton(
                icon: const Icon(Icons.copy, size: 20),
                onPressed: widget.onCopy,
              ),
          ],
        ),
      ],
    );
  }
}

/// Simple PIN verification dialog
class _PinVerifyDialog extends ConsumerStatefulWidget {
  @override
  ConsumerState<_PinVerifyDialog> createState() => _PinVerifyDialogState();
}

class _PinVerifyDialogState extends ConsumerState<_PinVerifyDialog> {
  final _pinController = TextEditingController();
  bool _verifying = false;
  String? _error;

  @override
  void dispose() {
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    final pin = _pinController.text;
    if (pin.isEmpty) return;

    setState(() { _verifying = true; _error = null; });

    final pinAuth = ref.read(pinAuthProvider);
    final valid = await pinAuth.verifyPin(pin);

    if (valid) {
      if (mounted) Navigator.pop(context, true);
    } else {
      setState(() { _verifying = false; _error = 'Incorrect PIN'; _pinController.clear(); });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Enter PIN'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _pinController,
            keyboardType: TextInputType.number,
            obscureText: true,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'PIN',
              border: const OutlineInputBorder(),
              errorText: _error,
            ),
            onSubmitted: (_) => _verify(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _verifying ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _verifying ? null : _verify,
          child: _verifying
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Verify'),
        ),
      ],
    );
  }
}

/// Dialog for adding a new vault entry
class AddEntryDialog extends ConsumerStatefulWidget {
  final VoidCallback onSaved;

  const AddEntryDialog({super.key, required this.onSaved});

  @override
  ConsumerState<AddEntryDialog> createState() => _AddEntryDialogState();
}

class _AddEntryDialogState extends ConsumerState<AddEntryDialog> {
  final _titleController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _urlController = TextEditingController();
  final _notesController = TextEditingController();
  final _groupController = TextEditingController();

  bool _obscurePassword = true;
  bool _saving = false;

  @override
  void dispose() {
    _titleController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _urlController.dispose();
    _notesController.dispose();
    _groupController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add Password'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _titleController,
              decoration: const InputDecoration(
                labelText: 'Title',
                hintText: 'e.g., Gmail',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _usernameController,
              decoration: const InputDecoration(
                labelText: 'Username/Email',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordController,
              decoration: InputDecoration(
                labelText: 'Password',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(_obscurePassword ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                ),
              ),
              obscureText: _obscurePassword,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _groupController,
              decoration: const InputDecoration(
                labelText: 'Group (optional)',
                hintText: 'e.g., Social, Work, Finance',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.folder_outlined),
              ),
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _urlController,
              decoration: const InputDecoration(
                labelText: 'URL (optional)',
                hintText: 'https://example.com',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _notesController,
              decoration: const InputDecoration(
                labelText: 'Notes (optional)',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _saveEntry,
          child: _saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Save'),
        ),
      ],
    );
  }

  Future<void> _saveEntry() async {
    if (_titleController.text.isEmpty ||
        _usernameController.text.isEmpty ||
        _passwordController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill in Title, Username, and Password')),
      );
      return;
    }

    setState(() => _saving = true);

    try {
      final repo = ref.read(vaultRepositoryProvider);
      await repo.initialize();

      final group = _groupController.text.trim();
      final tags = group.isNotEmpty ? [group] : <String>[];

      await repo.createEntry(
        title: _titleController.text.trim(),
        username: _usernameController.text.trim(),
        password: _passwordController.text,
        url: _urlController.text.trim().isEmpty ? null : _urlController.text.trim(),
        notes: _notesController.text.trim().isEmpty ? null : _notesController.text.trim(),
        tags: tags,
      );

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

/// Widget to display TOTP code with countdown timer
class _TotpCodeRow extends StatefulWidget {
  final String totpSecret;

  const _TotpCodeRow({required this.totpSecret});

  @override
  State<_TotpCodeRow> createState() => _TotpCodeRowState();
}

class _TotpCodeRowState extends State<_TotpCodeRow> {
  Timer? _timer;
  int _secondsRemaining = 30;
  int _currentPeriod = 0;

  @override
  void initState() {
    super.initState();
    _secondsRemaining = TotpGenerator.getSecondsRemaining();
    _currentPeriod = TotpGenerator.getCurrentPeriod();
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) {
        final newPeriod = TotpGenerator.getCurrentPeriod();
        if (newPeriod != _currentPeriod || _secondsRemaining != TotpGenerator.getSecondsRemaining()) {
          setState(() {
            _secondsRemaining = TotpGenerator.getSecondsRemaining();
            _currentPeriod = newPeriod;
          });
        }
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final code = TotpGenerator.generateCode(widget.totpSecret) ?? '------';
    final formattedCode = code.length == 6 ? '${code.substring(0, 3)} ${code.substring(3)}' : code;
    final isExpiring = _secondsRemaining <= 5;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('2FA Code', style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant)),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  formattedCode,
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 4,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 32,
              height: 32,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  CircularProgressIndicator(
                    value: _secondsRemaining / 30,
                    strokeWidth: 2,
                    color: isExpiring ? Colors.orange : colorScheme.primary,
                    backgroundColor: colorScheme.outlineVariant,
                  ),
                  Text(
                    '$_secondsRemaining',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: isExpiring ? Colors.orange : colorScheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.copy, size: 20),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: code));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Copied: $code'),
                    duration: const Duration(seconds: 2),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              },
            ),
          ],
        ),
      ],
    );
  }
}

/// Dialog for editing an existing vault entry
class EditEntryDialog extends ConsumerStatefulWidget {
  final VaultEntry entry;
  final VoidCallback onSaved;

  const EditEntryDialog({super.key, required this.entry, required this.onSaved});

  @override
  ConsumerState<EditEntryDialog> createState() => _EditEntryDialogState();
}

class _EditEntryDialogState extends ConsumerState<EditEntryDialog> {
  late final TextEditingController _titleController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;
  late final TextEditingController _urlController;
  late final TextEditingController _notesController;
  late final TextEditingController _groupController;

  bool _obscurePassword = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.entry.title);
    _usernameController = TextEditingController(text: widget.entry.username);
    _passwordController = TextEditingController(text: widget.entry.password);
    _urlController = TextEditingController(text: widget.entry.url ?? '');
    _notesController = TextEditingController(text: widget.entry.notes ?? '');
    _groupController = TextEditingController(
      text: widget.entry.tags.isNotEmpty ? widget.entry.tags.first : '',
    );
  }

  @override
  void dispose() {
    _titleController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _urlController.dispose();
    _notesController.dispose();
    _groupController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit Password'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _titleController,
              decoration: const InputDecoration(
                labelText: 'Title',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _usernameController,
              decoration: const InputDecoration(
                labelText: 'Username/Email',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordController,
              decoration: InputDecoration(
                labelText: 'Password',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(_obscurePassword ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                ),
              ),
              obscureText: _obscurePassword,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _groupController,
              decoration: const InputDecoration(
                labelText: 'Group (optional)',
                hintText: 'e.g., Social, Work, Finance',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.folder_outlined),
              ),
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _urlController,
              decoration: const InputDecoration(
                labelText: 'URL (optional)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _notesController,
              decoration: const InputDecoration(
                labelText: 'Notes (optional)',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _updateEntry,
          child: _saving
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Save'),
        ),
      ],
    );
  }

  Future<void> _updateEntry() async {
    if (_titleController.text.isEmpty ||
        _usernameController.text.isEmpty ||
        _passwordController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill in Title, Username, and Password')),
      );
      return;
    }

    setState(() => _saving = true);

    try {
      final repo = ref.read(vaultRepositoryProvider);
      await repo.initialize();

      final group = _groupController.text.trim();
      final tags = group.isNotEmpty ? [group] : <String>[];

      final updated = widget.entry.copyWith(
        title: _titleController.text.trim(),
        username: _usernameController.text.trim(),
        password: _passwordController.text,
        url: _urlController.text.trim().isEmpty ? null : _urlController.text.trim(),
        notes: _notesController.text.trim().isEmpty ? null : _notesController.text.trim(),
        tags: tags,
      );

      await repo.updateEntry(updated);
      widget.onSaved();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update: $e')),
        );
      }
    }
  }
}
