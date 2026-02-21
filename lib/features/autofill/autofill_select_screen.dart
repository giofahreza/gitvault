import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/models/vault_entry.dart';
import '../../core/providers/providers.dart';

/// Extract the registered domain from a URL string (strips www.).
String? _extractDomain(String? url) {
  if (url == null || url.isEmpty) return null;
  try {
    final uri = Uri.parse(url.startsWith('http') ? url : 'https://$url');
    return uri.host.replaceFirst('www.', '');
  } catch (_) {
    return null;
  }
}

/// Filter vault entries that match the given autofill package/domain context.
List<VaultEntry> filterForAutofill(
  List<VaultEntry> entries,
  String? packageName,
  String? domain,
) {
  return entries.where((entry) {
    final title = entry.title.toLowerCase();
    final notes = (entry.notes ?? '').toLowerCase();
    final entryUrl = (entry.url ?? '').toLowerCase();

    if (domain != null && domain.isNotEmpty) {
      final domainLower = domain.toLowerCase();
      // Precise: compare extracted domains
      final entryDomain = _extractDomain(entry.url);
      if (entryDomain != null &&
          (domainLower.contains(entryDomain) || entryDomain.contains(domainLower))) {
        return true;
      }
      // Fallback: substring matching on title / notes / url
      if (title.contains(domainLower) ||
          notes.contains(domainLower) ||
          entryUrl.contains(domainLower)) {
        return true;
      }
    }

    if (packageName != null && packageName.isNotEmpty) {
      final packageLower = packageName.toLowerCase();
      // Check both directions: title in package (e.g. "google" in "com.google.android.gm")
      // and package in title/notes (for entries that store the full package name)
      if (title.contains(packageLower) ||
          packageLower.contains(title) ||
          notes.contains(packageLower)) {
        return true;
      }
    }

    return false;
  }).toList();
}

class AutofillSelectScreen extends ConsumerStatefulWidget {
  final String? packageName;
  final String? domain;

  const AutofillSelectScreen({
    super.key,
    this.packageName,
    this.domain,
  });

  @override
  ConsumerState<AutofillSelectScreen> createState() => _AutofillSelectScreenState();
}

class _AutofillSelectScreenState extends ConsumerState<AutofillSelectScreen> {
  List<VaultEntry> _matchingEntries = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadMatchingEntries();
  }

  Future<void> _loadMatchingEntries() async {
    if (!mounted) return;

    setState(() => _isLoading = true);

    try {
      final vaultRepository = ref.read(vaultRepositoryProvider);

      // Initialize repository first
      try {
        await vaultRepository.initialize();
      } catch (e) {
        // If initialization fails, vault might not be set up
        print('Vault initialization error: $e');
        if (mounted) {
          setState(() {
            _matchingEntries = [];
            _isLoading = false;
          });
        }
        return;
      }

      final entries = await vaultRepository.getAllEntries();

      // Filter matching entries using shared helper
      final matching = filterForAutofill(entries, widget.packageName, widget.domain);

      setState(() {
        _matchingEntries = matching;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading entries: $e')),
        );
      }
    }
  }

  Future<void> _cancel() async {
    final autofillService = ref.read(autofillServiceProvider);
    await autofillService.cancelAutofill();
  }

  Future<void> _selectEntry(VaultEntry entry) async {
    try {
      // Provide credentials to autofill system — MainActivity.setAutofillResult()
      // will call finish(), so we don't need to pop manually.
      final autofillService = ref.read(autofillServiceProvider);
      await autofillService.provideAutofillData(
        username: entry.username,
        password: entry.password,
      );
    } catch (e) {
      print('AutofillSelectScreen: Error providing autofill data: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Select Account'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: _cancel,
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    if (_matchingEntries.isEmpty) {
      return _buildEmptyState();
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _matchingEntries.length,
      itemBuilder: (context, index) {
        final entry = _matchingEntries[index];
        return _buildEntryCard(entry);
      },
    );
  }

  Widget _buildEmptyState() {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.search_off,
            size: 64,
            color: colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(
            'No matching accounts',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            widget.domain ?? widget.packageName ?? 'this app',
            style: TextStyle(color: colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: _cancel,
            icon: const Icon(Icons.close),
            label: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  Widget _buildEntryCard(VaultEntry entry) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          child: Icon(
            Icons.person,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        title: Text(
          entry.title,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
          ),
        ),
        subtitle: entry.username.isNotEmpty
            ? Text(
                entry.username,
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
              )
            : null,
        trailing: const Icon(Icons.arrow_forward_ios, size: 16),
        onTap: () => _selectEntry(entry),
      ),
    );
  }
}
