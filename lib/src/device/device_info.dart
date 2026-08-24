enum DeviceConnection { attached, wireless, both }

final class DeviceInfo {
  const DeviceInfo({
    required this.id,
    required this.name,
    required this.platform,
    required this.platformType,
    required this.connectionInterface,
    required this.emulator,
    required this.ephemeral,
    required this.sdk,
  });

  factory DeviceInfo.fromMap(Map<String, Object?> map) {
    return DeviceInfo(
      id: map['id'] as String? ?? '',
      name: map['name'] as String? ?? 'Unknown device',
      platform: map['platform'] as String? ?? 'unknown',
      platformType: map['platformType'] as String? ?? 'unknown',
      connectionInterface: map['connectionInterface'] as String? ?? 'attached',
      emulator: map['emulator'] as bool? ?? false,
      ephemeral: map['ephemeral'] as bool? ?? true,
      sdk: map['sdk'] as String? ?? 'unknown',
    );
  }

  final String id;
  final String name;
  final String platform;
  final String platformType;
  final String connectionInterface;
  final bool emulator;
  final bool ephemeral;
  final String sdk;

  bool get isSupportedPhysicalMobile =>
      !emulator && (platformType == 'android' || platformType == 'ios');

  bool isAllowedBy(DeviceConnection connection) {
    return switch (connection) {
      DeviceConnection.both => true,
      DeviceConnection.attached => connectionInterface == 'attached',
      DeviceConnection.wireless => connectionInterface == 'wireless',
    };
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'platform': platform,
        'platformType': platformType,
        'connectionInterface': connectionInterface,
        'emulator': emulator,
        'ephemeral': ephemeral,
        'sdk': sdk,
      };
}

final class DeviceFingerprint {
  const DeviceFingerprint({
    required this.platformType,
    required this.stableId,
    required this.fallbackId,
    required this.name,
    required this.platform,
    required this.sdk,
  });

  final String platformType;
  final String stableId;
  final String fallbackId;
  final String name;
  final String platform;
  final String sdk;

  bool matches(DeviceFingerprint other) {
    if (platformType != other.platformType) {
      return false;
    }
    if (stableId.isNotEmpty && other.stableId.isNotEmpty) {
      return stableId == other.stableId;
    }
    if (fallbackId == other.fallbackId) {
      return true;
    }
    return name == other.name && platform == other.platform && sdk == other.sdk;
  }
}

final class TrackedDevice {
  const TrackedDevice({required this.info, required this.fingerprint});

  final DeviceInfo info;
  final DeviceFingerprint fingerprint;
}
