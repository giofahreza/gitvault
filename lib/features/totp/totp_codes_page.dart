import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/providers.dart';
import '../../data/models/vault_entry.dart';
import '../../utils/totp_generator.dart';
import 'totp_scanner_screen.dart';
import 'google_auth_import_screen.dart';

/// Dedicated 2FA codes page - shows all TOTP codes like Google Authenticator
class TotpCodesPage extends ConsumerStatefulWidget {
  const TotpCodesPage({super.key});

  @override
  ConsumerState<TotpCodesPage> createState() => _TotpCodesPageState();
}

class _TotpCodesPageState extends ConsumerState<TotpCodesPage> {
  Timer? _timer;
  int _secondsRemaining = 30;
  int _currentPeriod = 0;
  final _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _secondsRemaining = TotpGenerator.getSecondsRemaining();
    _currentPeriod = TotpGenerator.getCurrentPeriod();
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) {
        final newPeriod = TotpGenerator.getCurrentPeriod();
        setState(() {
          _secondsRemaining = TotpGenerator.getSecondsRemaining();
          _currentPeriod = newPeriod;
        });
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entriesAsync = ref.watch(vaultEntriesProvider);

    return Scaffold(
      appBar: AppBar(
        title: _searchQuery.isEmpty
            ? const Text('2FA Codes')
            : TextField(
                controller: _searchController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Search 2FA codes...',
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
          PopupMenuButton<String>(
            onSelected: (value) {
              switch (value) {
                case 'scan':
                  _scanQrCode();
                  break;
                case 'import':
                  _importFromGoogleAuth();
                  break;
                case 'info':
                  _showInfoDialog();
                  break;
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'scan',
                child: ListTile(
                  leading: Icon(Icons.qr_code_scanner),
                  title: Text('Scan QR Code'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: 'import',
                child: ListTile(
                  leading: Icon(Icons.import_export),
                  title: Text('Import from Google Authenticator'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: 'info',
                child: ListTile(
                  leading: Icon(Icons.info_outline),
                  title: Text('About 2FA'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      body: entriesAsync.when(
        data: (entries) {
          // Filter entries that have TOTP secrets
          var totpEntries = entries.where((e) => e.totpSecret != null && e.totpSecret!.isNotEmpty).toList();

          // Apply search filter
          if (_searchQuery.isNotEmpty) {
            final query = _searchQuery.toLowerCase();
            totpEntries = totpEntries.where((e) {
              return e.title.toLowerCase().contains(query) ||
                  (e.username.isNotEmpty && e.username.toLowerCase().contains(query));
            }).toList();
          }

          if (totpEntries.isEmpty && _searchQuery.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.security, size: 64, color: Colors.grey.shade400),
                  const SizedBox(height: 16),
                  Text(
                    'No 2FA Codes',
                    style: TextStyle(fontSize: 18, color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Tap + to add manually, or scan a QR code',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey.shade500),
                  ),
                  const SizedBox(height: 24),
                  OutlinedButton.icon(
                    onPressed: _scanQrCode,
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('Scan QR Code'),
                  ),
                ],
              ),
            );
          }

          return totpEntries.isEmpty
              ? Center(
                  child: Text(
                    'No matching 2FA codes',
                    style: TextStyle(color: Colors.grey.shade600),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: () async {
                    ref.invalidate(vaultEntriesProvider);
                  },
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: totpEntries.length,
                    itemBuilder: (context, index) {
                      final entry = totpEntries[index];
                      return _TotpCodeCard(
                        key: ValueKey('${entry.uuid}_$_currentPeriod'),
                        entry: entry,
                        secondsRemaining: _secondsRemaining,
                      );
                    },
                  ),
                );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, stack) => Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 16),
              Text('Error: $err'),
            ],
          ),
        ),
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton.small(
            heroTag: 'scan_qr',
            onPressed: _scanQrCode,
            child: const Icon(Icons.qr_code_scanner),
          ),
          const SizedBox(height: 8),
          FloatingActionButton(
            heroTag: 'add_manual',
            onPressed: () => _showAddTotpDialog(),
            child: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }

  Future<void> _scanQrCode() async {
    final result = await Navigator.of(context).push<Map<String, String>>(
      MaterialPageRoute(builder: (_) => const TotpScannerScreen()),
    );

    if (result == null || !mounted) return;

    // Check if this is a migration URI
    if (result.containsKey('migration')) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => GoogleAuthImportScreen(migrationUri: result['migration']!),
        ),
      ).then((_) => ref.invalidate(vaultEntriesProvider));
      return;
    }

    // Auto-populate from scanned data
    _showAddTotpDialog(
      issuer: result['issuer'] ?? '',
      account: result['account'] ?? '',
      secret: result['secret'] ?? '',
    );
  }

  void _importFromGoogleAuth() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const GoogleAuthImportScreen()),
    ).then((_) => ref.invalidate(vaultEntriesProvider));
  }

  void _showAddTotpDialog({String? issuer, String? account, String? secret}) {
    showDialog(
      context: context,
      builder: (context) => _AddTotpDialog(
        initialIssuer: issuer,
        initialAccount: account,
        initialSecret: secret,
        onSaved: () {
          ref.invalidate(vaultEntriesProvider);
        },
      ),
    );
  }

  void _showInfoDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('About 2FA Codes'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Time-based One-Time Passwords (TOTP) provide an extra layer of security for your accounts.'),
            SizedBox(height: 12),
            Text('• Codes refresh every 30 seconds'),
            Text('• Compatible with Google Authenticator'),
            Text('• Scan QR codes to add accounts'),
            Text('• Import from Google Authenticator'),
            Text('• Tap a code to copy it'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }
}

/// Card displaying a single TOTP code
class _TotpCodeCard extends StatelessWidget {
  final VaultEntry entry;
  final int secondsRemaining;

  const _TotpCodeCard({
    super.key,
    required this.entry,
    required this.secondsRemaining,
  });

  @override
  Widget build(BuildContext context) {
    final code = TotpGenerator.generateCode(entry.totpSecret ?? '') ?? '------';
    final colorScheme = Theme.of(context).colorScheme;

    // Color changes to warning when < 5 seconds remaining
    final isExpiring = secondsRemaining <= 5;
    final progressColor = isExpiring ? Colors.orange : colorScheme.primary;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: () => _copyCode(context, code),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Title and issuer
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.title,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (entry.username.isNotEmpty)
                          Text(
                            entry.username,
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.grey.shade600,
                            ),
                          ),
                      ],
                    ),
                  ),
                  // Countdown timer
                  SizedBox(
                    width: 40,
                    height: 40,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        CircularProgressIndicator(
                          value: secondsRemaining / 30,
                          strokeWidth: 3,
                          color: progressColor,
                          backgroundColor: Colors.grey.shade300,
                        ),
                        Text(
                          '$secondsRemaining',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: isExpiring ? Colors.orange : colorScheme.onSurface,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // TOTP Code
              Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _formatCode(code),
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 4,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.copy),
                    onPressed: () => _copyCode(context, code),
                    tooltip: 'Copy code',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatCode(String code) {
    // Format 6-digit code as "123 456"
    if (code.length == 6) {
      return '${code.substring(0, 3)} ${code.substring(3)}';
    }
    return code;
  }

  void _copyCode(BuildContext context, String code) {
    Clipboard.setData(ClipboardData(text: code));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied: $code'),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

/// Dialog for adding a standalone 2FA code (like Google Authenticator)
class _AddTotpDialog extends ConsumerStatefulWidget {
  final String? initialIssuer;
  final String? initialAccount;
  final String? initialSecret;
  final VoidCallback onSaved;

  const _AddTotpDialog({
    this.initialIssuer,
    this.initialAccount,
    this.initialSecret,
    required this.onSaved,
  });

  @override
  ConsumerState<_AddTotpDialog> createState() => _AddTotpDialogState();
}

class _AddTotpDialogState extends ConsumerState<_AddTotpDialog> {
  late final TextEditingController _titleController;
  late final TextEditingController _accountController;
  late final TextEditingController _totpSecretController;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.initialIssuer ?? '');
    _accountController = TextEditingController(text: widget.initialAccount ?? '');
    _totpSecretController = TextEditingController(text: widget.initialSecret ?? '');
  }

  @override
  void dispose() {
    _titleController.dispose();
    _accountController.dispose();
    _totpSecretController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add 2FA Code'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _titleController,
              decoration: const InputDecoration(
                labelText: 'Service Name',
                hintText: 'e.g., Google, GitHub, Facebook',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.business),
              ),
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _accountController,
              decoration: const InputDecoration(
                labelText: 'Account (optional)',
                hintText: 'e.g., user@example.com',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.person),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _totpSecretController,
              decoration: const InputDecoration(
                labelText: 'Secret Key',
                hintText: 'Enter Base32 secret',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.key),
              ),
              textCapitalization: TextCapitalization.characters,
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
          onPressed: _saving ? null : _save2faCode,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Add'),
        ),
      ],
    );
  }

  Future<void> _save2faCode() async {
    if (_titleController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a service name')),
      );
      return;
    }

    final secret = _totpSecretController.text.trim();
    if (secret.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a secret key')),
      );
      return;
    }

    // Validate secret
    if (!TotpGenerator.isValidSecret(secret)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invalid secret key. Must be valid Base32.')),
      );
      return;
    }

    setState(() => _saving = true);

    try {
      final repo = ref.read(vaultRepositoryProvider);
      await repo.initialize();

      // Create a standalone 2FA entry (password field empty, marked as 2FA-only)
      await repo.createEntry(
        title: _titleController.text.trim(),
        username: _accountController.text.trim(),
        password: '', // Empty password for 2FA-only entries
        totpSecret: secret,
      );

      widget.onSaved();

      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('2FA code added successfully')),
        );
      }
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
