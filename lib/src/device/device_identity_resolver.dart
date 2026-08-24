import 'dart:async';
import 'dart:io';

import 'device_info.dart';

typedef ExternalCommandRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

Future<ProcessResult> runExternalCommand(
  String executable,
  List<String> arguments,
) =>
    Process.run(executable, arguments);

final class DeviceIdentityResolver {
  const DeviceIdentityResolver({
    this.commandRunner = runExternalCommand,
    this.adbExecutable = 'adb',
  });

  final ExternalCommandRunner commandRunner;
  final String adbExecutable;

  Future<DeviceFingerprint> resolve(DeviceInfo device) async {
    final stableId = switch (device.platformType) {
      'android' when !device.emulator => await _androidSerial(device),
      'ios' => device.id,
      _ => device.id,
    };
    return DeviceFingerprint(
      platformType: device.platformType,
      stableId: stableId,
      fallbackId: device.id,
      name: device.name,
      platform: device.platform,
      sdk: device.sdk,
    );
  }

  Future<String> _androidSerial(DeviceInfo device) async {
    try {
      final result = await commandRunner(
        adbExecutable,
        ['-s', device.id, 'shell', 'getprop', 'ro.serialno'],
      ).timeout(const Duration(seconds: 3));
      if (result.exitCode == 0) {
        final serial = result.stdout.toString().trim();
        if (serial.isNotEmpty) {
          return serial;
        }
      }
    } on Object {
      return '';
    }
    return '';
  }
}
