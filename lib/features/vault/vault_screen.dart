import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/providers.dart';
import '../../core/services/github_service.dart';
import '../../data/models/vault_entry.dart';
import '../../data/repositories/sync_engine.dart';
import '../../utils/totp_generator.dart';
import '../../utils/auth_helper.dart';
import '../../utils/pointer_focus.dart';

/// Main vault screen displaying all password entries grouped by category
class VaultScreen extends ConsumerStatefulWidget {
  const VaultScreen({super.key});

  @override
  ConsumerState<VaultScreen> createState() => _VaultScreenState();
}

class _VaultScreenState extends ConsumerState<VaultScreen> {
  final _searchController = TextEditingController();
  late final FocusNode _searchFocusNode;
  String _searchQuery = '';
  bool _isSearching = false;
  final Set<String> _collapsedGroups = {};
  String? _copiedPasswordUuid;
  Timer? _copyFeedbackTimer;

  @override
  void initState() {
    super.initState();
    _searchFocusNode = FocusNode(onKeyEvent: _handleSearchKey);
  }

  @override
  void dispose() {
    _searchController.clear();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _copyFeedbackTimer?.cancel();
    super.dispose();
  }

  KeyEventResult _handleSearchKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape &&
        _isSearching) {
      _clearSearch();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final entriesAsync = ref.watch(vaultEntriesProvider);

    return Scaffold(
      appBar: AppBar(
        title: !_isSearching
            ? const Text('Passwords')
            : PointerFocus(
                focusNode: _searchFocusNode,
                child: TextField(
                  controller: _searchController,
                  focusNode: _searchFocusNode,
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: 'Search passwords...',
                    border: InputBorder.none,
                  ),
                  style: const TextStyle(fontSize: 18),
                  onChanged: (value) => setState(() => _searchQuery = value),
                ),
              ),
        actions: [
          if (!_isSearching)
            IconButton(
              icon: const Icon(Icons.search),
              tooltip: 'Search',
              onPressed: _startSearch,
            )
          else
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Close search',
              onPressed: _clearSearch,
            ),
        ],
      ),
      body: entriesAsync.when(
        data: (entries) => _buildVaultList(entries),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => Center(child: Text('Error: $err')),
      ),
      floatingActionButton: Semantics(
        label: 'Add password',
        button: true,
        child: FloatingActionButton(
          tooltip: 'Add password',
          onPressed: () => _showAddEntryDialog(),
          child: const Icon(Icons.add),
        ),
      ),
    );
  }

  void _startSearch() {
    setState(() {
      _isSearching = true;
      _searchQuery = '';
      _searchController.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocusNode.requestFocus();
    });
  }

  void _clearSearch() {
    setState(() {
      _isSearching = false;
      _searchQuery = '';
      _searchController.clear();
    });
    FocusScope.of(context).unfocus();
  }

  String _getGroup(VaultEntry entry) {
    if (entry.tags.isNotEmpty && entry.tags.first.isNotEmpty) {
      return entry.tags.first;
    }
    return 'Ungrouped';
  }

  Widget _buildVaultList(List<VaultEntry> entries) {
    // Filter out 2FA-only entries (entries with empty passwords)
    final passwordEntries =
        entries.where((e) => e.password.isNotEmpty).toList();

    final trimmedQuery = _searchQuery.trim().toLowerCase();
    final filtered = trimmedQuery.isEmpty
        ? passwordEntries
        : passwordEntries.where((e) {
            return e.title.toLowerCase().contains(trimmedQuery) ||
                e.username.toLowerCase().contains(trimmedQuery) ||
                (e.url?.toLowerCase().contains(trimmedQuery) ?? false) ||
                e.tags.any((t) => t.toLowerCase().contains(trimmedQuery));
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
              style:
                  TextStyle(fontSize: 16, color: colorScheme.onSurfaceVariant),
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
        padding: const EdgeInsets.only(bottom: 96),
        itemCount: filtered.length,
        itemBuilder: (context, index) {
          final entry = filtered[index];
          return _VaultEntryTile(
            entry: entry,
            passwordCopied: _copiedPasswordUuid == entry.uuid,
            onTap: () => _showEntryDetails(entry),
            onCopy: () => _copyPassword(entry),
            onEdit: () => _showEditEntryDialog(entry),
            onLongPress: () => _showEditEntryDialog(entry),
          );
        },
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 96),
      itemCount: sortedGroups.length,
      itemBuilder: (context, index) {
        final group = sortedGroups[index];
        final groupEntries = grouped[group]!;
        final isCollapsed = _collapsedGroups.contains(group);

        return _GroupSection(
          groupName: group,
          entries: groupEntries,
          isCollapsed: isCollapsed,
          onToggle: () {
            setState(() {
              if (isCollapsed) {
                _collapsedGroups.remove(group);
              } else {
                _collapsedGroups.add(group);
              }
            });
          },
          onEntryTap: _showEntryDetails,
          onEntryCopy: _copyPassword,
          onEntryEdit: _showEditEntryDialog,
          onEntryLongPress: _showEditEntryDialog,
          copiedPasswordUuid: _copiedPasswordUuid,
        );
      },
    );
  }

  Future<void> _copyPassword(VaultEntry entry) async {
    // Require biometric or PIN auth before copying
    final authenticated = await AuthHelper.authenticate(
      context: context,
      ref: ref,
      reason: 'Authenticate to copy password',
    );

    if (authenticated && mounted) {
      _performCopy(entry);
    }
  }

  void _performCopy(VaultEntry entry) {
    Clipboard.setData(ClipboardData(text: entry.password));
    _copyFeedbackTimer?.cancel();
    setState(() => _copiedPasswordUuid = entry.uuid);
    _copyFeedbackTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copiedPasswordUuid = null);
    });

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('Password copied to clipboard'),
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
          margin: EdgeInsets.fromLTRB(16, 0, 16, 88),
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
            const SnackBar(
                content: Text('Username copied'),
                duration: Duration(seconds: 2)),
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
        onDelete: () => _showDeleteConfirmation(entry),
      ),
    );
  }

  Future<void> _showDeleteConfirmation(VaultEntry entry) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Entry'),
        content: Text('Are you sure you want to delete "${entry.title}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
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

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Entry deleted'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Future<void> _syncVault() async {
    final keyStorage = ref.read(keyStorageProvider);
    await keyStorage.initialize();
    final hasGitHub = await keyStorage.hasGitHubCredentials();

    if (!hasGitHub) {
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
        throw Exception(
            'GitHub credentials incomplete. Please reconfigure in Settings.');
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
          SnackBar(
              content: Text(message),
              backgroundColor: Theme.of(context).colorScheme.tertiary),
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
  final void Function(VaultEntry) onEntryCopy;
  final void Function(VaultEntry) onEntryEdit;
  final void Function(VaultEntry) onEntryLongPress;
  final String? copiedPasswordUuid;

  const _GroupSection({
    required this.groupName,
    required this.entries,
    required this.isCollapsed,
    required this.onToggle,
    required this.onEntryTap,
    required this.onEntryCopy,
    required this.onEntryEdit,
    required this.onEntryLongPress,
    required this.copiedPasswordUuid,
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
                passwordCopied: copiedPasswordUuid == entry.uuid,
                onTap: () => onEntryTap(entry),
                onCopy: () => onEntryCopy(entry),
                onEdit: () => onEntryEdit(entry),
                onLongPress: () => onEntryLongPress(entry),
              )),
        const Divider(height: 1),
      ],
    );
  }
}

class _VaultEntryTile extends StatelessWidget {
  final VaultEntry entry;
  final VoidCallback onTap;
  final VoidCallback onCopy;
  final VoidCallback onEdit;
  final VoidCallback onLongPress;
  final bool passwordCopied;

  const _VaultEntryTile({
    required this.entry,
    required this.onTap,
    required this.onCopy,
    required this.onEdit,
    required this.onLongPress,
    required this.passwordCopied,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final semanticLabel = [
      'Password entry',
      entry.title,
      if (entry.username.isNotEmpty) 'username ${entry.username}',
    ].join(', ');

    return Semantics(
      container: true,
      label: semanticLabel,
      button: true,
      child: ListTile(
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
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: passwordCopied ? 'Password copied' : 'Copy password',
              icon: Icon(
                passwordCopied ? Icons.check_circle : Icons.copy_outlined,
              ),
              color: passwordCopied ? colorScheme.primary : null,
              onPressed: onCopy,
            ),
            IconButton(
              tooltip: 'Edit password',
              icon: const Icon(Icons.edit_outlined),
              onPressed: onEdit,
            ),
          ],
        ),
        onTap: onTap,
        onLongPress: onLongPress,
      ),
    );
  }
}

class _EntryDetailsSheet extends ConsumerWidget {
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

  Future<void> _showDelete2FAConfirmation(
      BuildContext context, VaultEntry entry) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove 2FA'),
        content:
            const Text('Are you sure you want to remove 2FA from this entry?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirm == true && context.mounted) {
      // Remove 2FA from entry
      final ref = ProviderScope.containerOf(context);
      final repo = ref.read(vaultRepositoryProvider);
      await repo.initialize();

      final updated = entry.copyWith(totpSecret: null);
      await repo.updateEntry(updated);
      ref.invalidate(vaultEntriesProvider);

      if (context.mounted) {
        Navigator.pop(context); // Close the details sheet
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('2FA removed'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final mediaQuery = MediaQuery.of(context);
    final isDesktop = mediaQuery.size.width >= 720;
    final initialSize = isDesktop && mediaQuery.size.height < 760 ? 0.82 : 0.64;

    return DraggableScrollableSheet(
      initialChildSize: initialSize,
      minChildSize: isDesktop ? 0.5 : 0.35,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
            child: Scrollbar(
              controller: scrollController,
              thumbVisibility: isDesktop,
              child: ListView(
                controller: scrollController,
                padding: EdgeInsets.only(
                  bottom: 24 + mediaQuery.viewPadding.bottom,
                ),
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: colorScheme.outlineVariant,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(entry.title,
                      style: const TextStyle(
                          fontSize: 24, fontWeight: FontWeight.bold)),
                  if (entry.tags.isNotEmpty && entry.tags.first.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      children: [
                        Chip(
                          label: Text(entry.tags.first,
                              style: const TextStyle(fontSize: 12)),
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 24),
                  _DetailRow(
                      label: 'Username',
                      value: entry.username,
                      onCopy: onCopyUsername),
                  const SizedBox(height: 12),
                  _DetailRow(
                      label: 'Password',
                      value: entry.password,
                      obscured: true,
                      onCopy: onCopyPassword),
                  if (entry.totpSecret != null &&
                      entry.totpSecret!.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _TotpCodeRow(
                      totpSecret: entry.totpSecret!,
                      onEdit: onEdit,
                    ),
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
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: onCopyUsername,
                        icon: const Icon(Icons.person_outline),
                        label: const Text('Copy Username'),
                      ),
                      FilledButton.icon(
                        onPressed: onCopyPassword,
                        icon: const Icon(Icons.copy_outlined),
                        label: const Text('Copy Password'),
                      ),
                      OutlinedButton.icon(
                        onPressed: onEdit,
                        icon: const Icon(Icons.edit_outlined),
                        label: const Text('Edit'),
                      ),
                      OutlinedButton.icon(
                        onPressed: onDelete,
                        icon: Icon(Icons.delete_outline,
                            color: colorScheme.error),
                        label: Text(
                          'Delete',
                          style: TextStyle(color: colorScheme.error),
                        ),
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(color: colorScheme.error),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
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

    final authenticated = await AuthHelper.authenticate(
      context: context,
      ref: ref,
      reason: 'Authenticate to view password',
    );

    if (authenticated && mounted) {
      setState(() => _hidden = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final displayValue =
        (widget.obscured && _hidden) ? '••••••••' : widget.value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.label,
            style:
                TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant)),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
                child:
                    Text(displayValue, style: const TextStyle(fontSize: 16))),
            if (widget.obscured)
              IconButton(
                tooltip: _hidden ? 'Show password' : 'Hide password',
                icon: Icon(_hidden ? Icons.visibility : Icons.visibility_off,
                    size: 20),
                onPressed: _togglePasswordVisibility,
              ),
            if (widget.onCopy != null)
              IconButton(
                tooltip: 'Copy ${widget.label.toLowerCase()}',
                icon: const Icon(Icons.copy, size: 20),
                onPressed: widget.onCopy,
              ),
          ],
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
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _urlController = TextEditingController();
  final _notesController = TextEditingController();
  final _groupController = TextEditingController();
  final _titleFocus = FocusNode();
  final _usernameFocus = FocusNode();
  final _passwordFocus = FocusNode();
  final _groupFocus = FocusNode();
  final _urlFocus = FocusNode();
  final _notesFocus = FocusNode();

  bool _obscurePassword = true;
  bool _saving = false;
  bool _authenticated = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _titleFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _titleController.clear();
    _usernameController.clear();
    _passwordController.clear();
    _urlController.clear();
    _notesController.clear();
    _groupController.clear();
    _titleController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _urlController.dispose();
    _notesController.dispose();
    _groupController.dispose();
    _titleFocus.dispose();
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    _groupFocus.dispose();
    _urlFocus.dispose();
    _notesFocus.dispose();
    super.dispose();
  }

  Future<void> _togglePasswordVisibility() async {
    if (!_obscurePassword) {
      setState(() => _obscurePassword = true);
      return;
    }

    final authenticated = await AuthHelper.authenticate(
      context: context,
      ref: ref,
      reason: 'Authenticate to view password',
    );

    if (authenticated && mounted) {
      setState(() {
        _obscurePassword = false;
        _authenticated = true;
      });
    }
  }

  void _focusNext(FocusNode focusNode) {
    focusNode.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && focusNode.canRequestFocus) {
        focusNode.requestFocus();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add Password'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: FocusTraversalGroup(
            policy: OrderedTraversalPolicy(),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FocusTraversalOrder(
                  order: const NumericFocusOrder(1),
                  child: PointerFocus(
                    focusNode: _titleFocus,
                    child: TextFormField(
                      controller: _titleController,
                      focusNode: _titleFocus,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: 'Title',
                        hintText: 'e.g., Gmail',
                        border: OutlineInputBorder(),
                      ),
                      enabled: !_saving,
                      textInputAction: TextInputAction.next,
                      onFieldSubmitted: (_) => _focusNext(_usernameFocus),
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                              ? 'Title is required'
                              : null,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                FocusTraversalOrder(
                  order: const NumericFocusOrder(2),
                  child: PointerFocus(
                    focusNode: _usernameFocus,
                    child: TextFormField(
                      controller: _usernameController,
                      focusNode: _usernameFocus,
                      decoration: const InputDecoration(
                        labelText: 'Username/Email',
                        border: OutlineInputBorder(),
                      ),
                      enabled: !_saving,
                      textInputAction: TextInputAction.next,
                      onFieldSubmitted: (_) => _focusNext(_passwordFocus),
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                              ? 'Username or email is required'
                              : null,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                FocusTraversalOrder(
                  order: const NumericFocusOrder(3),
                  child: PointerFocus(
                    focusNode: _passwordFocus,
                    child: TextFormField(
                      controller: _passwordController,
                      focusNode: _passwordFocus,
                      decoration: InputDecoration(
                        labelText: 'Password',
                        border: const OutlineInputBorder(),
                        suffixIcon: ExcludeFocus(
                          child: IconButton(
                            tooltip: _obscurePassword
                                ? 'Show password'
                                : 'Hide password',
                            icon: Icon(_obscurePassword
                                ? Icons.visibility
                                : Icons.visibility_off),
                            onPressed: _togglePasswordVisibility,
                          ),
                        ),
                      ),
                      obscureText: _obscurePassword,
                      enabled: !_saving,
                      textInputAction: TextInputAction.next,
                      onFieldSubmitted: (_) => _focusNext(_groupFocus),
                      validator: (value) => value == null || value.isEmpty
                          ? 'Password is required'
                          : null,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                FocusTraversalOrder(
                  order: const NumericFocusOrder(4),
                  child: PointerFocus(
                    focusNode: _groupFocus,
                    child: TextFormField(
                      controller: _groupController,
                      focusNode: _groupFocus,
                      decoration: const InputDecoration(
                        labelText: 'Group (optional)',
                        hintText: 'e.g., Social, Work, Finance',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.folder_outlined),
                      ),
                      enabled: !_saving,
                      textCapitalization: TextCapitalization.words,
                      textInputAction: TextInputAction.next,
                      onFieldSubmitted: (_) => _focusNext(_urlFocus),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                FocusTraversalOrder(
                  order: const NumericFocusOrder(5),
                  child: PointerFocus(
                    focusNode: _urlFocus,
                    child: TextFormField(
                      controller: _urlController,
                      focusNode: _urlFocus,
                      decoration: const InputDecoration(
                        labelText: 'URL (optional)',
                        hintText: 'https://example.com',
                        border: OutlineInputBorder(),
                      ),
                      enabled: !_saving,
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.next,
                      onFieldSubmitted: (_) => _focusNext(_notesFocus),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                FocusTraversalOrder(
                  order: const NumericFocusOrder(6),
                  child: PointerFocus(
                    focusNode: _notesFocus,
                    child: TextFormField(
                      controller: _notesController,
                      focusNode: _notesFocus,
                      decoration: const InputDecoration(
                        labelText: 'Notes (optional)',
                        border: OutlineInputBorder(),
                      ),
                      enabled: !_saving,
                      maxLines: 3,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _saveEntry,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Save'),
        ),
      ],
    );
  }

  Future<void> _saveEntry() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
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
        url: _urlController.text.trim().isEmpty
            ? null
            : _urlController.text.trim(),
        notes: _notesController.text.trim().isEmpty
            ? null
            : _notesController.text.trim(),
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
  final VoidCallback onEdit;

  const _TotpCodeRow({
    required this.totpSecret,
    required this.onEdit,
  });

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
        if (newPeriod != _currentPeriod ||
            _secondsRemaining != TotpGenerator.getSecondsRemaining()) {
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
    final formattedCode = code.length == 6
        ? '${code.substring(0, 3)} ${code.substring(3)}'
        : code;
    final isExpiring = _secondsRemaining <= 5;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('2FA Code',
            style:
                TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant)),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: GestureDetector(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: code));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Copied: $code'),
                      duration: const Duration(seconds: 2),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                },
                onLongPress: widget.onEdit,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
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
              tooltip: 'Copy 2FA code',
              icon: const Icon(Icons.copy_outlined, size: 20),
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
            IconButton(
              tooltip: 'Edit 2FA',
              icon: const Icon(Icons.edit_outlined, size: 20),
              onPressed: widget.onEdit,
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
  final VoidCallback onDelete;

  const EditEntryDialog({
    super.key,
    required this.entry,
    required this.onSaved,
    required this.onDelete,
  });

  @override
  ConsumerState<EditEntryDialog> createState() => _EditEntryDialogState();
}

class _EditEntryDialogState extends ConsumerState<EditEntryDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;
  late final TextEditingController _urlController;
  late final TextEditingController _notesController;
  late final TextEditingController _groupController;
  final _titleFocus = FocusNode();
  final _usernameFocus = FocusNode();
  final _passwordFocus = FocusNode();
  final _groupFocus = FocusNode();
  final _urlFocus = FocusNode();
  final _notesFocus = FocusNode();

  bool _obscurePassword = true;
  bool _saving = false;
  bool _authenticated = false;

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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _titleFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _titleController.clear();
    _usernameController.clear();
    _passwordController.clear();
    _urlController.clear();
    _notesController.clear();
    _groupController.clear();
    _titleController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _urlController.dispose();
    _notesController.dispose();
    _groupController.dispose();
    _titleFocus.dispose();
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    _groupFocus.dispose();
    _urlFocus.dispose();
    _notesFocus.dispose();
    super.dispose();
  }

  Future<void> _togglePasswordVisibility() async {
    if (!_obscurePassword) {
      setState(() => _obscurePassword = true);
      return;
    }

    final authenticated = await AuthHelper.authenticate(
      context: context,
      ref: ref,
      reason: 'Authenticate to view password',
    );

    if (authenticated && mounted) {
      setState(() {
        _obscurePassword = false;
        _authenticated = true;
      });
    }
  }

  void _focusNext(FocusNode focusNode) {
    focusNode.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && focusNode.canRequestFocus) {
        focusNode.requestFocus();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit Password'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: FocusTraversalGroup(
            policy: OrderedTraversalPolicy(),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FocusTraversalOrder(
                  order: const NumericFocusOrder(1),
                  child: PointerFocus(
                    focusNode: _titleFocus,
                    child: TextFormField(
                      controller: _titleController,
                      focusNode: _titleFocus,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: 'Title',
                        border: OutlineInputBorder(),
                      ),
                      enabled: !_saving,
                      textInputAction: TextInputAction.next,
                      onFieldSubmitted: (_) => _focusNext(_usernameFocus),
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                              ? 'Title is required'
                              : null,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                FocusTraversalOrder(
                  order: const NumericFocusOrder(2),
                  child: PointerFocus(
                    focusNode: _usernameFocus,
                    child: TextFormField(
                      controller: _usernameController,
                      focusNode: _usernameFocus,
                      decoration: const InputDecoration(
                        labelText: 'Username/Email',
                        border: OutlineInputBorder(),
                      ),
                      enabled: !_saving,
                      textInputAction: TextInputAction.next,
                      onFieldSubmitted: (_) => _focusNext(_passwordFocus),
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                              ? 'Username or email is required'
                              : null,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                FocusTraversalOrder(
                  order: const NumericFocusOrder(3),
                  child: PointerFocus(
                    focusNode: _passwordFocus,
                    child: TextFormField(
                      controller: _passwordController,
                      focusNode: _passwordFocus,
                      decoration: InputDecoration(
                        labelText: 'Password',
                        border: const OutlineInputBorder(),
                        suffixIcon: ExcludeFocus(
                          child: IconButton(
                            tooltip: _obscurePassword
                                ? 'Show password'
                                : 'Hide password',
                            icon: Icon(_obscurePassword
                                ? Icons.visibility
                                : Icons.visibility_off),
                            onPressed: _togglePasswordVisibility,
                          ),
                        ),
                      ),
                      obscureText: _obscurePassword,
                      enabled: !_saving,
                      textInputAction: TextInputAction.next,
                      onFieldSubmitted: (_) => _focusNext(_groupFocus),
                      validator: (value) => value == null || value.isEmpty
                          ? 'Password is required'
                          : null,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                FocusTraversalOrder(
                  order: const NumericFocusOrder(4),
                  child: PointerFocus(
                    focusNode: _groupFocus,
                    child: TextFormField(
                      controller: _groupController,
                      focusNode: _groupFocus,
                      decoration: const InputDecoration(
                        labelText: 'Group (optional)',
                        hintText: 'e.g., Social, Work, Finance',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.folder_outlined),
                      ),
                      enabled: !_saving,
                      textCapitalization: TextCapitalization.words,
                      textInputAction: TextInputAction.next,
                      onFieldSubmitted: (_) => _focusNext(_urlFocus),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                FocusTraversalOrder(
                  order: const NumericFocusOrder(5),
                  child: PointerFocus(
                    focusNode: _urlFocus,
                    child: TextFormField(
                      controller: _urlController,
                      focusNode: _urlFocus,
                      decoration: const InputDecoration(
                        labelText: 'URL (optional)',
                        border: OutlineInputBorder(),
                      ),
                      enabled: !_saving,
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.next,
                      onFieldSubmitted: (_) => _focusNext(_notesFocus),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                FocusTraversalOrder(
                  order: const NumericFocusOrder(6),
                  child: PointerFocus(
                    focusNode: _notesFocus,
                    child: TextFormField(
                      controller: _notesController,
                      focusNode: _notesFocus,
                      decoration: const InputDecoration(
                        labelText: 'Notes (optional)',
                        border: OutlineInputBorder(),
                      ),
                      enabled: !_saving,
                      maxLines: 3,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                if (widget.entry.totpSecret != null &&
                    widget.entry.totpSecret!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        final confirm = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('Remove 2FA'),
                            content: const Text(
                                'Are you sure you want to remove 2FA from this entry?'),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, false),
                                child: const Text('Cancel'),
                              ),
                              FilledButton(
                                style: FilledButton.styleFrom(
                                  backgroundColor:
                                      Theme.of(context).colorScheme.error,
                                ),
                                onPressed: () => Navigator.pop(ctx, true),
                                child: const Text('Remove'),
                              ),
                            ],
                          ),
                        );
                        if (confirm == true && mounted) {
                          final repo = ref.read(vaultRepositoryProvider);
                          await repo.initialize();
                          final updated =
                              widget.entry.copyWith(totpSecret: null);
                          await repo.updateEntry(updated);
                          widget.onSaved();
                          if (mounted) {
                            Navigator.of(context).pop();
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('2FA removed')),
                            );
                          }
                        }
                      },
                      icon: const Icon(Icons.remove_circle_outline),
                      label: const Text('Remove 2FA'),
                    ),
                  ),
                OutlinedButton.icon(
                  onPressed: () {
                    Navigator.of(context).pop();
                    widget.onDelete();
                  },
                  icon: Icon(Icons.delete_outline,
                      color: Theme.of(context).colorScheme.error),
                  label: Text('Delete Entry',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                  style: OutlinedButton.styleFrom(
                    side:
                        BorderSide(color: Theme.of(context).colorScheme.error),
                  ),
                ),
              ],
            ),
          ),
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
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Save'),
        ),
      ],
    );
  }

  Future<void> _updateEntry() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
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
        url: _urlController.text.trim().isEmpty
            ? null
            : _urlController.text.trim(),
        notes: _notesController.text.trim().isEmpty
            ? null
            : _notesController.text.trim(),
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
