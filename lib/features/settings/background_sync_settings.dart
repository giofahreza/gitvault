import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/providers/providers.dart';
import '../../core/services/background_sync_service.dart';
import '../../core/services/battery_optimization_manager.dart';
import '../../core/services/connectivity_manager.dart';

/// Background sync settings screen
class BackgroundSyncSettings extends ConsumerStatefulWidget {
  const BackgroundSyncSettings({super.key});

  @override
  ConsumerState<BackgroundSyncSettings> createState() => _BackgroundSyncSettingsState();
}

class _BackgroundSyncSettingsState extends ConsumerState<BackgroundSyncSettings> {
  bool _isEnabled = false;
  int _syncInterval = 60;
  bool _requireWifi = false;
  bool _requireCharging = false;
  bool _isLoading = true;
  bool _isSyncing = false;

  Map<String, dynamic>? _syncStats;
  BatteryOptimizationStatus? _batteryStatus;
  ConnectivityStatus? _connectivityStatus;

  final BatteryOptimizationManager _batteryManager = BatteryOptimizationManager();
  final ConnectivityManager _connectivityManager = ConnectivityManager();

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadStatus();
  }

  Future<void> _loadSettings() async {
    final enabled = await BackgroundSyncService.isEnabled();
    final interval = await BackgroundSyncService.getSyncInterval();
    final stats = await BackgroundSyncService.getSyncStats();

    setState(() {
      _isEnabled = enabled;
      _syncInterval = interval;
      _syncStats = stats;
      _isLoading = false;
    });
  }

  Future<void> _loadStatus() async {
    final battery = await _batteryManager.getOptimizationStatus();
    final connectivity = await _connectivityManager.getConnectivityStatus();

    setState(() {
      _batteryStatus = battery;
      _connectivityStatus = connectivity;
    });
  }

  Future<void> _toggleBackgroundSync(bool value) async {
    setState(() => _isLoading = true);

    if (value) {
      await BackgroundSyncService.enableBackgroundSync(
        intervalMinutes: _syncInterval,
        requireWifi: _requireWifi,
        requireCharging: _requireCharging,
      );
    } else {
      await BackgroundSyncService.disableBackgroundSync();
    }

    await _loadSettings();
  }

  Future<void> _updateInterval(int value) async {
    setState(() {
      _syncInterval = value;
      _isLoading = true;
    });

    if (_isEnabled) {
      await BackgroundSyncService.enableBackgroundSync(
        intervalMinutes: value,
        requireWifi: _requireWifi,
        requireCharging: _requireCharging,
      );
    }

    await _loadSettings();
  }

  Future<void> _updateWifiRequirement(bool value) async {
    setState(() {
      _requireWifi = value;
      _isLoading = true;
    });

    if (_isEnabled) {
      await BackgroundSyncService.enableBackgroundSync(
        intervalMinutes: _syncInterval,
        requireWifi: value,
        requireCharging: _requireCharging,
      );
    }

    await _loadSettings();
  }

  Future<void> _updateChargingRequirement(bool value) async {
    setState(() {
      _requireCharging = value;
      _isLoading = true;
    });

    if (_isEnabled) {
      await BackgroundSyncService.enableBackgroundSync(
        intervalMinutes: _syncInterval,
        requireWifi: _requireWifi,
        requireCharging: value,
      );
    }

    await _loadSettings();
  }

  Future<void> _triggerManualSync() async {
    if (_isSyncing) return;
    setState(() => _isSyncing = true);

    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Row(
          children: [
            SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
            SizedBox(width: 12),
            Text('Syncing with GitHub...'),
          ],
        ),
        duration: Duration(minutes: 2),
      ),
    );

    try {
      final result = await BackgroundSyncService.performSyncNow();

      if (mounted) {
        // Invalidate repository providers — this cascades to invalidate all
        // list providers (vaultEntriesProvider, notesProvider, etc.) and forces
        // fresh repository instances so newly synced Hive data is always read.
        ref.invalidate(vaultRepositoryProvider);
        ref.invalidate(notesRepositoryProvider);
        ref.invalidate(sshRepositoryProvider);
        ref.invalidate(archivedNotesProvider);

        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Sync complete — pushed: ${result.pushed}, pulled: ${result.pulled}${result.conflicts > 0 ? ", conflicts: ${result.conflicts}" : ""}'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 4),
          ),
        );
        await _loadSettings();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Sync failed: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 6),
          ),
        );
        await _loadSettings();
      }
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Background Sync'),
      ),
      body: _isLoading && _syncStats == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Enable/Disable
                Card(
                  child: SwitchListTile(
                    title: const Text('Enable Background Sync'),
                    subtitle: const Text('Automatically sync vault in background'),
                    value: _isEnabled,
                    onChanged: _toggleBackgroundSync,
                  ),
                ),
                const SizedBox(height: 16),

                // Sync Interval
                if (_isEnabled) ...[
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Sync Interval: ${_syncInterval} minutes',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Slider(
                            value: _syncInterval.toDouble(),
                            min: 15,
                            max: 360,
                            divisions: 23,
                            label: '$_syncInterval min',
                            onChanged: (value) => _updateInterval(value.toInt()),
                          ),
                          Text(
                            'More frequent sync uses more battery',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Requirements
                  Card(
                    child: Column(
                      children: [
                        SwitchListTile(
                          title: const Text('WiFi Only'),
                          subtitle: const Text('When off, syncs on WiFi or mobile data'),
                          value: _requireWifi,
                          onChanged: _updateWifiRequirement,
                        ),
                        const Divider(height: 1),
                        SwitchListTile(
                          title: const Text('Charging Only'),
                          subtitle: const Text('Sync only when device is charging'),
                          value: _requireCharging,
                          onChanged: _updateChargingRequirement,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ],

                // Status Cards
                _buildBatteryStatus(),
                const SizedBox(height: 16),
                _buildConnectivityStatus(),
                const SizedBox(height: 16),

                // Sync Stats
                if (_syncStats != null) _buildSyncStats(),
                const SizedBox(height: 16),

                // Manual Sync Button
                ElevatedButton.icon(
                  onPressed: _isSyncing ? null : _triggerManualSync,
                  icon: _isSyncing
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.sync),
                  label: Text(_isSyncing ? 'Syncing...' : 'Sync Now'),
                ),
              ],
            ),
    );
  }

  Widget _buildBatteryStatus() {
    if (_batteryStatus == null) {
      return const Card(
        child: ListTile(
          leading: Icon(Icons.battery_unknown),
          title: Text('Loading battery status...'),
        ),
      );
    }

    final status = _batteryStatus!;
    IconData icon;
    Color? iconColor;

    if (status.isCharging) {
      icon = Icons.battery_charging_full;
      iconColor = Colors.green;
    } else if (status.isCritical) {
      icon = Icons.battery_alert;
      iconColor = Colors.red;
    } else if (status.batteryLevel < 20) {
      icon = Icons.battery_2_bar;
      iconColor = Colors.orange;
    } else {
      icon = Icons.battery_full;
      iconColor = Colors.green;
    }

    return Card(
      child: ListTile(
        leading: Icon(icon, color: iconColor),
        title: const Text('Battery Status'),
        subtitle: Text(
          '${status.batteryLevel}% ${status.isCharging ? "(Charging)" : ""}\n'
          'Recommended interval: ${status.recommendedInterval} min',
        ),
        isThreeLine: true,
      ),
    );
  }

  Widget _buildConnectivityStatus() {
    if (_connectivityStatus == null) {
      return const Card(
        child: ListTile(
          leading: Icon(Icons.wifi_off),
          title: Text('Loading connectivity...'),
        ),
      );
    }

    final status = _connectivityStatus!;
    IconData icon;
    Color? iconColor;
    String subtitle;

    if (!status.isConnected) {
      icon = Icons.wifi_off;
      iconColor = Colors.red;
      subtitle = 'No internet connection';
    } else if (status.isWifi) {
      icon = Icons.wifi;
      iconColor = Colors.green;
      subtitle = 'Connected to WiFi';
    } else if (status.isCellular) {
      icon = Icons.signal_cellular_4_bar;
      iconColor = Colors.orange;
      subtitle = 'Connected to cellular (metered)';
    } else {
      icon = Icons.network_check;
      iconColor = Colors.blue;
      subtitle = 'Connected to ${status.connectionType.name}';
    }

    return Card(
      child: ListTile(
        leading: Icon(icon, color: iconColor),
        title: const Text('Network Status'),
        subtitle: Text(subtitle),
      ),
    );
  }

  Widget _buildSyncStats() {
    final stats = _syncStats!;
    final lastSync = stats['last_sync'] as DateTime?;
    final lastSuccess = stats['last_success'] as bool;
    final lastError = stats['last_error'] as String?;
    final failures = stats['consecutive_failures'] as int;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Sync Statistics',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            _buildStatRow('Last Sync', lastSync != null
                ? _formatDateTime(lastSync)
                : 'Never'),
            _buildStatRow('Status', lastSuccess ? 'Success' : 'Failed'),
            if (lastError != null)
              _buildStatRow('Last Error', lastError),
            if (failures > 0)
              _buildStatRow('Consecutive Failures', failures.toString()),
          ],
        ),
      ),
    );
  }

  Widget _buildStatRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }

  String _formatDateTime(DateTime dateTime) {
    final now = DateTime.now();
    final diff = now.difference(dateTime);

    if (diff.inSeconds < 60) {
      return 'Just now';
    } else if (diff.inMinutes < 60) {
      return '${diff.inMinutes}m ago';
    } else if (diff.inHours < 24) {
      return '${diff.inHours}h ago';
    } else {
      return '${diff.inDays}d ago';
    }
  }

  @override
  void dispose() {
    _connectivityManager.dispose();
    super.dispose();
  }
}
