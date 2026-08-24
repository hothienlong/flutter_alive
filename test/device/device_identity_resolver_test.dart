import 'dart:io';

import 'package:flutter_alive/src/device/device_identity_resolver.dart';
import 'package:flutter_alive/src/device/device_info.dart';
import 'package:test/test.dart';

void main() {
  const usb = DeviceInfo(
    id: 'R5CXA4MJTPX',
    name: 'SM S721B',
    platform: 'android-arm64',
    platformType: 'android',
    connectionInterface: 'attached',
    emulator: false,
    ephemeral: true,
    sdk: 'Android 16',
  );
  const wireless = DeviceInfo(
    id: '192.168.1.20:5555',
    name: 'SM S721B',
    platform: 'android-arm64',
    platformType: 'android',
    connectionInterface: 'wireless',
    emulator: false,
    ephemeral: true,
    sdk: 'Android 16',
  );

  test('matches Android USB and wireless identities by hardware serial',
      () async {
    final resolver = DeviceIdentityResolver(
      commandRunner: (executable, arguments) async =>
          ProcessResult(1, 0, 'R5CXA4MJTPX\n', ''),
    );

    final usbFingerprint = await resolver.resolve(usb);
    final wirelessFingerprint = await resolver.resolve(wireless);

    expect(usbFingerprint.matches(wirelessFingerprint), isTrue);
  });

  test('falls back to exact ID and device metadata when adb is unavailable',
      () async {
    final resolver = DeviceIdentityResolver(
      commandRunner: (executable, arguments) =>
          throw const ProcessException('adb', []),
    );

    final usbFingerprint = await resolver.resolve(usb);
    final wirelessFingerprint = await resolver.resolve(wireless);

    expect(usbFingerprint.stableId, isEmpty);
    expect(usbFingerprint.fallbackId, usb.id);
    expect(usbFingerprint.matches(wirelessFingerprint), isTrue);
  });
}
