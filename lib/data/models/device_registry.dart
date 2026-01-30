import 'package:freezed_annotation/freezed_annotation.dart';

part 'device_registry.freezed.dart';
part 'device_registry.g.dart';

@freezed
class DeviceInfo with _$DeviceInfo {
  const factory DeviceInfo({
    required String deviceId,
    required String deviceName,
    required String publicKey,
    required DateTime addedAt,
    required DateTime lastSeenAt,
  }) = _DeviceInfo;

  factory DeviceInfo.fromJson(Map<String, dynamic> json) =>
      _$DeviceInfoFromJson(json);
}

@freezed
class DeviceRegistry with _$DeviceRegistry {
  const factory DeviceRegistry({
    required List<DeviceInfo> devices,
    required DateTime lastModified,
  }) = _DeviceRegistry;

  factory DeviceRegistry.fromJson(Map<String, dynamic> json) =>
      _$DeviceRegistryFromJson(json);
}
