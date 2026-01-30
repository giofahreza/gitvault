import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Settings and security controls screen
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: ListView(
        children: [
          const _SectionHeader(title: 'Security'),
          ListTile(
            leading: const Icon(Icons.fingerprint),
            title: const Text('Biometric Authentication'),
            subtitle: const Text('Enabled'),
            trailing: Switch(
              value: true,
              onChanged: (value) {
                // TODO: Toggle biometric auth
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.warning),
            title: const Text('Duress Mode'),
            subtitle: const Text('Configure panic PIN'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              // TODO: Navigate to duress mode setup
            },
          ),
          ListTile(
            leading: const Icon(Icons.timer),
            title: const Text('Clipboard Auto-Clear'),
            subtitle: const Text('Clear after 30 seconds'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              // TODO: Configure clipboard timeout
            },
          ),
          const Divider(),
          const _SectionHeader(title: 'Devices'),
          ListTile(
            leading: const Icon(Icons.phone_android),
            title: const Text('This Device'),
            subtitle: const Text('Primary'),
          ),
          ListTile(
            leading: const Icon(Icons.add),
            title: const Text('Link New Device'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              // TODO: Navigate to device linking
            },
          ),
          const Divider(),
          const _SectionHeader(title: 'Backup'),
          ListTile(
            leading: const Icon(Icons.cloud),
            title: const Text('GitHub Repository'),
            subtitle: const Text('Connected'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              // TODO: Show repo details
            },
          ),
          ListTile(
            leading: const Icon(Icons.download),
            title: const Text('Download Recovery Kit'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              // TODO: Generate and download recovery kit
            },
          ),
          const Divider(),
          const _SectionHeader(title: 'Danger Zone'),
          ListTile(
            leading: const Icon(Icons.delete_forever, color: Colors.red),
            title: const Text('Wipe All Data', style: TextStyle(color: Colors.red)),
            onTap: () {
              // TODO: Show confirmation and wipe
            },
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.bold,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}
