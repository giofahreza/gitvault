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
  List<MigrationAccount>? _accounts;
  Set<int> _selectedIndices = {};
  bool _importing = false;
  String? _error;
  bool _scanning = false;

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
      final accounts = GoogleAuthMigration.parseMigrationUri(uri);
      if (accounts.isEmpty) {
        setState(() => _error = 'No accounts found in the QR code.');
      } else {
        setState(() {
          _accounts = accounts;
          _selectedIndices = Set.from(List.generate(accounts.length, (i) => i));
          _scanning = false;
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
        title: const Text('Scan Google Authenticator Export'),
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

    if (_accounts == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final accounts = _accounts!;

    return Column(
      children: [
        // Header
        Container(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${accounts.length} accounts found',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
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
                  style: TextStyle(color: Colors.grey.shade600),
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

      int imported = 0;
      for (final index in _selectedIndices) {
        final account = _accounts![index];

        await repo.createEntry(
          title: account.issuer.isNotEmpty ? account.issuer : account.name,
          username: account.name,
          password: '',
          totpSecret: account.secret,
        );
        imported++;
      }

      ref.invalidate(vaultEntriesProvider);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Imported $imported account${imported == 1 ? '' : 's'} successfully'),
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
