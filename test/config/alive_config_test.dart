import 'dart:io';

import 'package:flutter_alive/src/config/alive_config.dart';
import 'package:flutter_alive/src/device/device_info.dart';
import 'package:test/test.dart';

void main() {
  test('loads project configuration', () async {
    final directory = await Directory.systemTemp.createTemp('alive-config-');
    addTearDown(() => directory.delete(recursive: true));
    await File('${directory.path}/.flutter_alive.yaml').writeAsString('''
flutter: /opt/flutter
device: phone
app_id: com.example.app
connection: wireless
attach_timeout_seconds: 12
reconnect_debounce_ms: 900
max_runner_retries: 5
runner_stability_seconds: 45
daemon_stability_seconds: 60
run_args:
  - --flavor
  - staging
''');

    final config = await AliveConfig.load(workingDirectory: directory.path);

    expect(config.flutterPath, '/opt/flutter');
    expect(config.device, 'phone');
    expect(config.appId, 'com.example.app');
    expect(config.connection, DeviceConnection.wireless);
    expect(config.attachTimeout, const Duration(seconds: 12));
    expect(config.reconnectDebounce, const Duration(milliseconds: 900));
    expect(config.maxRunnerRetries, 5);
    expect(config.runnerStabilityWindow, const Duration(seconds: 45));
    expect(config.daemonStabilityWindow, const Duration(seconds: 60));
    expect(config.runArguments, ['--flavor', 'staging']);
  });

  test('rejects invalid connection values', () async {
    final directory = await Directory.systemTemp.createTemp('alive-config-');
    addTearDown(() => directory.delete(recursive: true));
    await File('${directory.path}/.flutter_alive.yaml')
        .writeAsString('connection: cable\n');

    expect(
      () => AliveConfig.load(workingDirectory: directory.path),
      throwsA(isA<FormatException>()),
    );
  });
}
