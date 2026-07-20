import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../crypto/key_storage.dart';

class LocalDeviceIdentity {
  final String id;
  final String name;

  const LocalDeviceIdentity({
    required this.id,
    required this.name,
  });
}

class DeviceIdentityService {
  final KeyStorage _keyStorage;
  final DeviceInfoPlugin _deviceInfo;
  final Uuid _uuid;

  DeviceIdentityService({
    required KeyStorage keyStorage,
    DeviceInfoPlugin? deviceInfo,
    Uuid? uuid,
  })  : _keyStorage = keyStorage,
        _deviceInfo = deviceInfo ?? DeviceInfoPlugin(),
        _uuid = uuid ?? const Uuid();

  Future<LocalDeviceIdentity> ensureIdentity() async {
    await _keyStorage.initialize();

    final id = await getOrCreateDeviceId();
    final name = await getOrCreateDeviceName();

    return LocalDeviceIdentity(id: id, name: name);
  }

  Future<String> getOrCreateDeviceId() async {
    final existing = await _keyStorage.getDeviceId();
    if (existing != null && existing.trim().isNotEmpty) {
      return existing;
    }

    final generated = _uuid.v4();
    await _keyStorage.storeDeviceId(generated);
    return generated;
  }

  Future<String> getOrCreateDeviceName() async {
    final existing = await _keyStorage.getLocalDeviceName();
    if (existing != null && existing.trim().isNotEmpty) {
      return existing.trim();
    }

    final name = await _defaultDeviceName();
    await _keyStorage.storeLocalDeviceName(name);
    return name;
  }

  Future<void> renameCurrentDevice(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    await _keyStorage.storeLocalDeviceName(trimmed);
  }

  Future<String> _defaultDeviceName() async {
    try {
      if (kIsWeb) {
        final info = await _deviceInfo.webBrowserInfo;
        final browser = _formatBrowserName(info.browserName.name);
        final platform = info.platform?.trim();
        return platform == null || platform.isEmpty
            ? '$browser Browser'
            : '$browser on $platform';
      }

      switch (defaultTargetPlatform) {
        case TargetPlatform.android:
          final info = await _deviceInfo.androidInfo;
          final manufacturer = _titleCase(info.manufacturer);
          final model = info.model.trim();
          final parts = [manufacturer, model]
              .where((part) => part.isNotEmpty)
              .toSet()
              .join(' ');
          return parts.isEmpty ? 'Android Device' : parts;
        case TargetPlatform.iOS:
          final info = await _deviceInfo.iosInfo;
          final name = info.name.trim();
          if (name.isNotEmpty) return name;
          final model = info.model.trim();
          return model.isEmpty ? 'iPhone or iPad' : model;
        case TargetPlatform.macOS:
          final info = await _deviceInfo.macOsInfo;
          final name = info.computerName.trim();
          return name.isEmpty ? 'Mac' : name;
        case TargetPlatform.windows:
          final info = await _deviceInfo.windowsInfo;
          final name = info.computerName.trim();
          return name.isEmpty ? 'Windows PC' : name;
        case TargetPlatform.linux:
          final info = await _deviceInfo.linuxInfo;
          final name = info.prettyName.trim();
          return name.isEmpty ? 'Linux Device' : name;
        case TargetPlatform.fuchsia:
          return 'Fuchsia Device';
      }
    } catch (_) {
      return kIsWeb ? 'Web Browser' : 'This Device';
    }
  }

  String _formatBrowserName(String value) {
    switch (value) {
      case 'chrome':
        return 'Chrome';
      case 'edge':
        return 'Edge';
      case 'firefox':
        return 'Firefox';
      case 'safari':
        return 'Safari';
      case 'opera':
        return 'Opera';
      case 'samsungInternet':
        return 'Samsung Internet';
      default:
        return 'Web';
    }
  }

  String _titleCase(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return '';
    return trimmed
        .split(RegExp(r'\s+'))
        .map((word) => word.isEmpty
            ? word
            : '${word[0].toUpperCase()}${word.substring(1).toLowerCase()}')
        .join(' ');
  }
}
