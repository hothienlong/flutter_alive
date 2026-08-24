import 'dart:io';

import 'package:flutter_alive/src/device/device_info.dart';
import 'package:flutter_alive/src/process/managed_process.dart';
import 'package:flutter_alive/src/runner/flutter_runner_session.dart';
import 'package:test/test.dart';

import '../fakes/fake_flutter_harness.dart';

void main() {
  const device = DeviceInfo(
    id: 'phone-1',
    name: 'Test Phone',
    platform: 'android-arm64',
    platformType: 'android',
    connectionInterface: 'attached',
    emulator: false,
    ephemeral: true,
    sdk: 'Android 16',
  );

  test('starts flutter run in machine mode and accepts reload commands',
      () async {
    final harness = FakeFlutterHarness(device);
    final session = await FlutterRunnerSession.start(
      mode: RunnerMode.run,
      flutter: const ExecutableCommand('flutter'),
      deviceId: device.id,
      workingDirectory: Directory.current.path,
      runArguments: const ['--flavor', 'staging'],
      processStarter: harness.start,
      environment: const {},
    );

    await session.waitUntilStarted(timeout: const Duration(seconds: 1));

    expect(session.appId, isNotNull);
    expect(session.debugUri, startsWith('ws://'));
    expect(await session.reload(), isTrue);
    expect(await session.reload(fullRestart: true), isTrue);
    final invocation = harness.invocations.single;
    expect(invocation, containsAllInOrder(['run', '--machine']));
    expect(invocation, containsAllInOrder(['-d', device.id]));
    expect(invocation, containsAllInOrder(['--flavor', 'staging']));
    await session.stop();
  });

  test('filters run-only arguments when attaching', () async {
    final harness = FakeFlutterHarness(device);
    final session = await FlutterRunnerSession.start(
      mode: RunnerMode.attach,
      flutter: const ExecutableCommand('flutter'),
      deviceId: device.id,
      workingDirectory: Directory.current.path,
      runArguments: const [
        '--flavor',
        'staging',
        '--target=lib/main_staging.dart',
        '--dart-define=API_URL=test',
      ],
      processStarter: harness.start,
      environment: const {},
      appId: 'com.example.app',
    );

    await session.waitUntilStarted(timeout: const Duration(seconds: 1));

    final invocation = harness.invocations.single;
    expect(invocation, contains('attach'));
    expect(invocation, contains('--app-id=com.example.app'));
    expect(invocation, contains('--target=lib/main_staging.dart'));
    expect(invocation, contains('--dart-define=API_URL=test'));
    expect(invocation, isNot(contains('--flavor')));
    await session.detach();
  });

  test('marks lost device connections from app logs', () async {
    final harness = FakeFlutterHarness(device);
    final session = await FlutterRunnerSession.start(
      mode: RunnerMode.run,
      flutter: const ExecutableCommand('flutter'),
      deviceId: device.id,
      workingDirectory: Directory.current.path,
      runArguments: const [],
      processStarter: harness.start,
      environment: const {},
    );
    await session.waitUntilStarted(timeout: const Duration(seconds: 1));

    await harness.disconnect();

    expect(await session.exitCode, 1);
    expect(session.lostConnection, isTrue);
  });
}
