import 'package:flutter/material.dart';
import '../../core/services/persistent_ssh_service.dart';
import 'ssh_persistent_terminal_screen.dart';

/// SSH Sessions Manager - Like Termux sessions drawer
class SshSessionsScreen extends StatefulWidget {
  const SshSessionsScreen({super.key});

  @override
  State<SshSessionsScreen> createState() => _SshSessionsScreenState();
}

class _SshSessionsScreenState extends State<SshSessionsScreen> {
  final PersistentSshService _sshService = PersistentSshService();

  @override
  void initState() {
    super.initState();
    _sshService.initialize();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Active SSH Sessions'),
        actions: [
          if (_sshService.hasActiveSessions)
            IconButton(
              icon: const Icon(Icons.clear_all),
              tooltip: 'Close All Sessions',
              onPressed: _closeAllSessions,
            ),
        ],
      ),
      body: _buildSessionsList(),
    );
  }

  Widget _buildSessionsList() {
    final sessions = _sshService.getAllSessions();

    if (sessions.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.terminal,
              size: 64,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              'No active SSH sessions',
              style: TextStyle(
                fontSize: 16,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Sessions will appear here when you connect',
              style: TextStyle(
                fontSize: 14,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: sessions.length,
      itemBuilder: (context, index) {
        final session = sessions[index];
        return _buildSessionTile(session);
      },
    );
  }

  Widget _buildSessionTile(SshSessionWrapper session) {
    final duration = session.duration;
    final durationStr = _formatDuration(duration);

    return StreamBuilder<SshSessionState>(
      stream: session.stateStream,
      initialData: session.isConnected ? SshSessionState.connected : SshSessionState.disconnected,
      builder: (context, snapshot) {
        final state = snapshot.data ?? SshSessionState.disconnected;

        IconData statusIcon;
        Color statusColor;

        switch (state) {
          case SshSessionState.connecting:
            statusIcon = Icons.sync;
            statusColor = Colors.orange;
            break;
          case SshSessionState.connected:
            statusIcon = Icons.check_circle;
            statusColor = Colors.green;
            break;
          case SshSessionState.disconnected:
            statusIcon = Icons.cancel;
            statusColor = Colors.red;
            break;
          case SshSessionState.error:
            statusIcon = Icons.error;
            statusColor = Colors.red;
            break;
        }

        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: statusColor.withOpacity(0.2),
              child: Icon(statusIcon, color: statusColor, size: 20),
            ),
            title: Text(session.credential.label),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${session.credential.username}@${session.credential.host}:${session.credential.port}',
                  style: const TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(
                      Icons.access_time,
                      size: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      durationStr,
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            trailing: PopupMenuButton<String>(
              onSelected: (value) async {
                switch (value) {
                  case 'reconnect':
                    await session.reconnect();
                    setState(() {});
                    break;
                  case 'disconnect':
                    await _closeSession(session);
                    break;
                }
              },
              itemBuilder: (context) => [
                if (!session.isConnected)
                  const PopupMenuItem(
                    value: 'reconnect',
                    child: ListTile(
                      leading: Icon(Icons.refresh),
                      title: Text('Reconnect'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                const PopupMenuItem(
                  value: 'disconnect',
                  child: ListTile(
                    leading: Icon(Icons.close, color: Colors.red),
                    title: Text('Disconnect', style: TextStyle(color: Colors.red)),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
            onTap: () => _openSession(session),
          ),
        );
      },
    );
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);

    if (hours > 0) {
      return '${hours}h ${minutes}m';
    } else if (minutes > 0) {
      return '${minutes}m ${seconds}s';
    } else {
      return '${seconds}s';
    }
  }

  void _openSession(SshSessionWrapper session) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SshPersistentTerminalScreen(session: session),
      ),
    );
  }

  Future<void> _closeSession(SshSessionWrapper session) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Close Session'),
        content: Text('Close SSH session to ${session.credential.label}?'),
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
            child: const Text('Close'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _sshService.closeSession(session.sessionId);
      if (mounted) setState(() {});
    }
  }

  Future<void> _closeAllSessions() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Close All Sessions'),
        content: Text('Close all ${_sshService.activeSessionCount} active SSH sessions?'),
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
            child: const Text('Close All'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _sshService.closeAllSessions();
      if (mounted) setState(() {});
    }
  }
}
