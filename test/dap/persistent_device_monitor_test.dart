import 'dart:io';

import 'package:flutter_alive/src/dap/persistent_device_monitor.dart';
import 'package:flutter_alive/src/device/device_identity_resolver.dart';
import 'package:flutter_alive/src/device/device_info.dart';
import 'package:flutter_alive/src/process/managed_process.dart';
import 'package:test/test.dart';

import '../fakes/fake_flutter_harness.dart';

void main() {
  test('waits for the same Android device across USB and Wi-Fi IDs', () async {
    const usb = DeviceInfo(
      id: 'USB-DEVICE',
      name: 'Test Phone',
      platform: 'android-arm64',
      platformType: 'android',
      connectionInterface: 'attached',
      emulator: false,
      ephemeral: true,
      sdk: 'Android 16',
    );
    const wireless = DeviceInfo(
      id: '192.168.1.9:5555',
      name: 'Test Phone',
      platform: 'android-arm64',
      platformType: 'android',
      connectionInterface: 'wireless',
      emulator: false,
      ephemeral: true,
      sdk: 'Android 16',
    );
    final harness = FakeFlutterHarness(usb);
    final monitor = PersistentDeviceMonitor(
      flutter: const ExecutableCommand('flutter'),
      workingDirectory: Directory.current.path,
      processStarter: harness.start,
      environment: const {},
      delay: (_) async {},
      identityResolver: DeviceIdentityResolver(
        commandRunner: (executable, arguments) async =>
            ProcessResult(1, 0, 'HARDWARE-SERIAL\n', ''),
      ),
    );
    addTearDown(monitor.stop);

    expect((await monitor.waitForTarget(usb.id)).info.id, usb.id);
    await harness.disconnect();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final reconnected = monitor.waitForTarget(usb.id);
    harness.reconnect(wireless);

    expect((await reconnected).info.id, wireless.id);
  });
}
