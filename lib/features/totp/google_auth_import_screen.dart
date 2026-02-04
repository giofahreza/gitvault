import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/providers/providers.dart';
import '../../utils/google_auth_migration.dart';

/// Screen for importing TOTP accounts from Google Authenticator
class GoogleAuthImportScreen extends ConsumerStatefulWidget {
  final String? migrationUri;

  const GoogleAuthImportScreen({super.key, this.migrationUri});

  @override
  ConsumerState<GoogleAuthImportScreen> createState() => _GoogleAuthImportScreenState();
}

class _GoogleAuthImportScreenState extends ConsumerState<GoogleAuthImportScreen> {
  List<MigrationAccount> _accounts = [];
  Set<int> _selectedIndices = {};
  bool _importing = false;
  String? _error;
  bool _scanning = false;
  int _qrCodesScanned = 0;

  @override
  void initState() {
    super.initState();
    if (widget.migrationUri != null) {
      _parseMigrationData(widget.migrationUri!);
    } else {
      _scanning = true;
    }
  }

  void _parseMigrationData(String uri) {
    try {
      final newAccounts = GoogleAuthMigration.parseMigrationUri(uri);
      if (newAccounts.isEmpty) {
        setState(() => _error = 'No accounts found in the QR code.');
      } else {
        setState(() {
          final currentCount = _accounts.length;
          _accounts.addAll(newAccounts);
          // Select all newly added accounts
          _selectedIndices.addAll(
            List.generate(newAccounts.length, (i) => currentCount + i)
          );
          _qrCodesScanned++;
          _scanning = false;
          _error = null;
        });
      }
    } catch (e) {
      setState(() => _error = 'Failed to parse migration data: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_scanning) {
      return _buildScanner();
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Import from Google Authenticator'),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildScanner() {
    return Scaffold(
      appBar: AppBar(
        title: Text(_qrCodesScanned > 0
          ? 'Scan More QR Codes'
          : 'Scan Google Authenticator Export'),
        actions: [
          if (_qrCodesScanned > 0)
            TextButton(
              onPressed: () {
                setState(() {
                  _scanning = false;
                });
              },
              child: const Text('Done', style: TextStyle(color: Colors.white)),
            ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(
            onDetect: (capture) {
              for (final barcode in capture.barcodes) {
                final value = barcode.rawValue;
                if (value != null && value.startsWith('otpauth-migration://')) {
                  _parseMigrationData(value);
                  return;
                }
              }
            },
          ),
          Center(
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 2),
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          Positioned(
            bottom: 80,
            left: 0,
            right: 0,
            child: Column(
              children: [
                Text(
                  'Scan Google Authenticator export QR code',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    backgroundColor: Colors.black54,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'In Google Authenticator: ⋮ → Transfer accounts → Export',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    backgroundColor: Colors.black54,
                  ),
                ),
                if (_qrCodesScanned > 0) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.green,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '✓ Scanned $_qrCodesScanned QR code${_qrCodesScanned == 1 ? '' : 's'} - ${_accounts.length} accounts',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Scan next QR code or tap back to review',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      backgroundColor: Colors.black54,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 16),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 24),
              OutlinedButton(
                onPressed: () => setState(() {
                  _scanning = true;
                  _error = null;
                }),
                child: const Text('Try Again'),
              ),
            ],
          ),
        ),
      );
    }

    if (_accounts.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    final accounts = _accounts;

    return Column(
      children: [
        // Header
        Container(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${accounts.length} accounts found',
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                        if (_qrCodesScanned > 0)
                          Text(
                            'Scanned $_qrCodesScanned QR code${_qrCodesScanned == 1 ? '' : 's'}',
                            style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
                          ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      setState(() {
                        if (_selectedIndices.length == accounts.length) {
                          _selectedIndices.clear();
                        } else {
                          _selectedIndices = Set.from(List.generate(accounts.length, (i) => i));
                        }
                      });
                    },
                    child: Text(
                      _selectedIndices.length == accounts.length ? 'Deselect All' : 'Select All',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Scan More button
              OutlinedButton.icon(
                onPressed: _importing ? null : () {
                  setState(() {
                    _scanning = true;
                  });
                },
                icon: const Icon(Icons.qr_code_scanner, size: 18),
                label: const Text('Scan More QR Codes'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 36),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        // Account list
        Expanded(
          child: ListView.builder(
            itemCount: accounts.length,
            itemBuilder: (context, index) {
              final account = accounts[index];
              final selected = _selectedIndices.contains(index);

              return CheckboxListTile(
                value: selected,
                onChanged: _importing
                    ? null
                    : (value) {
                        setState(() {
                          if (value == true) {
                            _selectedIndices.add(index);
                          } else {
                            _selectedIndices.remove(index);
                          }
                        });
                      },
                title: Text(
                  account.issuer.isNotEmpty ? account.issuer : account.name,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  account.name.isNotEmpty && account.issuer.isNotEmpty
                      ? account.name
                      : account.type.toUpperCase(),
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
                secondary: CircleAvatar(
                  child: Text(
                    (account.issuer.isNotEmpty ? account.issuer : account.name)
                        .substring(0, 1)
                        .toUpperCase(),
                  ),
                ),
              );
            },
          ),
        ),
        // Import button
        Container(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _selectedIndices.isEmpty || _importing
                  ? null
                  : _importSelected,
              icon: _importing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.import_export),
              label: Text(
                _importing
                    ? 'Importing...'
                    : 'Import ${_selectedIndices.length} account${_selectedIndices.length == 1 ? '' : 's'}',
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _importSelected() async {
    setState(() => _importing = true);

    try {
      final repo = ref.read(vaultRepositoryProvider);
      await repo.initialize();

      // Get existing entries to check for duplicates
      final existingEntries = await repo.getAllEntries();
      final existingSecrets = existingEntries
          .where((e) => e.totpSecret != null && e.totpSecret!.isNotEmpty)
          .map((e) => e.totpSecret!.toUpperCase().replaceAll(' ', ''))
          .toSet();

      int imported = 0;
      int skipped = 0;

      for (final index in _selectedIndices) {
        final account = _accounts![index];
        final normalizedSecret = account.secret.toUpperCase().replaceAll(' ', '');

        // Skip if duplicate
        if (existingSecrets.contains(normalizedSecret)) {
          skipped++;
          continue;
        }

        await repo.createEntry(
          title: account.issuer.isNotEmpty ? account.issuer : account.name,
          username: account.name,
          password: '',
          totpSecret: account.secret,
        );

        // Add to existing set to prevent duplicates in this import batch
        existingSecrets.add(normalizedSecret);
        imported++;
      }

      ref.invalidate(vaultEntriesProvider);

      if (mounted) {
        String message = 'Imported $imported account${imported == 1 ? '' : 's'} successfully';
        if (skipped > 0) {
          message += ' ($skipped duplicate${skipped == 1 ? '' : 's'} skipped)';
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      setState(() => _importing = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Import failed: $e')),
        );
      }
    }
  }
}
