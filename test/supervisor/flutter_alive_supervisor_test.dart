import 'dart:async';
import 'dart:io';

import 'package:flutter_alive/src/config/alive_config.dart';
import 'package:flutter_alive/src/device/device_identity_resolver.dart';
import 'package:flutter_alive/src/device/device_info.dart';
import 'package:flutter_alive/src/process/managed_process.dart';
import 'package:flutter_alive/src/project/project_change_tracker.dart';
import 'package:flutter_alive/src/supervisor/flutter_alive_supervisor.dart';
import 'package:flutter_alive/src/supervisor/supervisor_state.dart';
import 'package:flutter_alive/src/ui/alive_reporter.dart';
import 'package:test/test.dart';

import '../fakes/fake_flutter_harness.dart';

const usbDevice = DeviceInfo(
  id: 'USB-DEVICE',
  name: 'Test Phone',
  platform: 'android-arm64',
  platformType: 'android',
  connectionInterface: 'attached',
  emulator: false,
  ephemeral: true,
  sdk: 'Android 16',
);

const wirelessDevice = DeviceInfo(
  id: '192.168.1.9:5555',
  name: 'Test Phone',
  platform: 'android-arm64',
  platformType: 'android',
  connectionInterface: 'wireless',
  emulator: false,
  ephemeral: true,
  sdk: 'Android 16',
);

void main() {
  test('keeps the parent alive and attaches after device reconnect', () async {
    final fixture = await _SupervisorFixture.create();
    addTearDown(fixture.dispose);

    await fixture.harness.waitForSessionCount(1);
    await _waitForState(fixture.supervisor, SupervisorState.running);

    await fixture.harness.disconnect();
    await _waitForState(fixture.supervisor, SupervisorState.disconnected);
    expect(fixture.completed, isFalse);

    fixture.harness.reconnect(wirelessDevice);
    await fixture.harness.waitForSessionCount(2);
    await _waitForState(fixture.supervisor, SupervisorState.running);
    expect(_runnerCommands(fixture.harness), ['run', 'attach']);
  });

  test('ignores duplicate device-added events while already running', () async {
    final fixture = await _SupervisorFixture.create();
    addTearDown(fixture.dispose);
    await fixture.harness.waitForSessionCount(1);
    await _waitForState(fixture.supervisor, SupervisorState.running);

    fixture.harness.reconnect(usbDevice);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(fixture.harness.sessions, hasLength(1));
    expect(fixture.supervisor.state, SupervisorState.running);
  });

  test('switches from USB to an already-discovered wireless connection',
      () async {
    final fixture = await _SupervisorFixture.create();
    addTearDown(fixture.dispose);
    await fixture.harness.waitForSessionCount(1);
    await _waitForState(fixture.supervisor, SupervisorState.running);

    await fixture.harness.switchConnection(
      from: usbDevice,
      to: wirelessDevice,
    );

    await fixture.harness.waitForSessionCount(2);
    await _waitForState(fixture.supervisor, SupervisorState.running);
    expect(_runnerCommands(fixture.harness), ['run', 'attach']);
  });

  test(
      'reconciles a device when the runner loses transport without daemon events',
      () async {
    final fixture = await _SupervisorFixture.create();
    addTearDown(fixture.dispose);
    await fixture.harness.waitForSessionCount(1);
    await _waitForState(fixture.supervisor, SupervisorState.running);

    await fixture.harness.loseRunnerConnectionWithoutDeviceEvent();

    await fixture.harness.waitForSessionCount(2);
    await _waitForState(fixture.supervisor, SupervisorState.running);
    expect(_runnerCommands(fixture.harness), ['run', 'attach']);
  });

  test('falls back to flutter run when attach fails', () async {
    final fixture = await _SupervisorFixture.create(attachFailures: 1);
    addTearDown(fixture.dispose);
    await fixture.harness.waitForSessionCount(1);
    await _waitForState(fixture.supervisor, SupervisorState.running);

    await fixture.harness.disconnect();
    fixture.harness.reconnect(wirelessDevice);

    await fixture.harness.waitForSessionCount(3);
    await _waitForState(fixture.supervisor, SupervisorState.running);
    expect(_runnerCommands(fixture.harness), ['run', 'attach', 'run']);
  });

  test('falls back to flutter run when attach times out', () async {
    final fixture = await _SupervisorFixture.create(
      attachHangs: 1,
      config: const AliveConfig(
        device: 'USB-DEVICE',
        attachTimeout: Duration(milliseconds: 50),
        reconnectDebounce: Duration(milliseconds: 10),
      ),
    );
    addTearDown(fixture.dispose);
    await fixture.harness.waitForSessionCount(1);
    await _waitForState(fixture.supervisor, SupervisorState.running);

    await fixture.harness.disconnect();
    fixture.harness.reconnect(wirelessDevice);

    await fixture.harness.waitForSessionCount(3);
    await _waitForState(fixture.supervisor, SupervisorState.running);
    expect(_runnerCommands(fixture.harness), ['run', 'attach', 'run']);
  });

  test('hot reloads source changes after a successful attach', () async {
    final fixture = await _SupervisorFixture.create();
    addTearDown(fixture.dispose);
    await fixture.harness.waitForSessionCount(1);
    await _waitForState(fixture.supervisor, SupervisorState.running);

    await fixture.harness.disconnect();
    await File('${fixture.project.path}/lib/main.dart')
        .writeAsString('void main() { print("changed"); }\n');
    await _waitUntil(
      () => fixture.changeTracker.dirtyKind == ProjectChangeKind.hot,
      'project tracker to observe a hot change',
    );
    fixture.harness.reconnect(wirelessDevice);

    await fixture.harness.waitForSessionCount(2);
    await _waitForState(fixture.supervisor, SupervisorState.running);
    final attach = fixture.harness.sessions[1];
    expect(
      attach.requests.any((request) => request['method'] == 'app.restart'),
      isTrue,
    );
  });

  test('skips attach when native files changed while disconnected', () async {
    final fixture = await _SupervisorFixture.create();
    addTearDown(fixture.dispose);
    await fixture.harness.waitForSessionCount(1);
    await _waitForState(fixture.supervisor, SupervisorState.running);

    await fixture.harness.disconnect();
    final androidDirectory = Directory('${fixture.project.path}/android/app');
    await File('${androidDirectory.path}/build.gradle')
        .writeAsString('// native change\n');
    await _waitUntil(
      () => fixture.changeTracker.dirtyKind == ProjectChangeKind.cold,
      'project tracker to observe a cold change',
    );
    fixture.harness.reconnect(wirelessDevice);

    await fixture.harness.waitForSessionCount(2);
    await _waitForState(fixture.supervisor, SupervisorState.running);
    expect(_runnerCommands(fixture.harness), ['run', 'run']);
  });

  test('restarts the Flutter daemon without ending the supervisor', () async {
    final fixture = await _SupervisorFixture.create();
    addTearDown(fixture.dispose);
    await fixture.harness.waitForSessionCount(1);
    await _waitForState(fixture.supervisor, SupervisorState.running);

    await fixture.harness.crashDaemon();

    await _waitUntil(
      () => fixture.harness.daemons.length >= 2,
      'a replacement Flutter daemon',
    );
    await fixture.harness.waitForSessionCount(2);
    await _waitForState(fixture.supervisor, SupervisorState.running);
    expect(fixture.completed, isFalse);
  });

  test('stops automatic runner retries at the configured limit', () async {
    final fixture = await _SupervisorFixture.create(
      config: const AliveConfig(
        device: 'USB-DEVICE',
        reconnectDebounce: Duration(milliseconds: 10),
        maxRunnerRetries: 2,
        runnerStabilityWindow: Duration(minutes: 1),
      ),
    );
    addTearDown(fixture.dispose);

    await fixture.harness.waitForSessionCount(1);
    await _waitForState(fixture.supervisor, SupervisorState.running);
    await fixture.harness.sessions[0].exit(1);

    await fixture.harness.waitForSessionCount(2);
    await _waitForState(fixture.supervisor, SupervisorState.running);
    await fixture.harness.sessions[1].exit(1);

    await fixture.harness.waitForSessionCount(3);
    await _waitForState(fixture.supervisor, SupervisorState.running);
    await fixture.harness.sessions[2].exit(1);

    await _waitForState(fixture.supervisor, SupervisorState.error);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(fixture.harness.sessions, hasLength(3));
    expect(fixture.completed, isFalse);
  });

  test('graceful shutdown closes the runner and daemon', () async {
    final fixture = await _SupervisorFixture.create();
    addTearDown(fixture.dispose);
    await fixture.harness.waitForSessionCount(1);
    await _waitForState(fixture.supervisor, SupervisorState.running);

    final runner = fixture.harness.sessions.single;
    final daemon = fixture.harness.daemons.single;
    await fixture.dispose();

    expect(await runner.exitCode, 0);
    expect(await daemon.exitCode, 0);
  });
}

List<String> _runnerCommands(FakeFlutterHarness harness) {
  return harness.invocations
      .where((arguments) =>
          arguments.contains('run') || arguments.contains('attach'))
      .map((arguments) => arguments.contains('attach') ? 'attach' : 'run')
      .toList(growable: false);
}

Future<void> _waitForState(
  FlutterAliveSupervisor supervisor,
  SupervisorState expected,
) {
  return _waitUntil(
    () => supervisor.state == expected,
    'state ${expected.name}; found ${supervisor.state.name}',
  );
}

Future<void> _waitUntil(bool Function() condition, String description) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Timed out waiting for $description.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

final class _SupervisorFixture {
  _SupervisorFixture({
    required this.project,
    required this.harness,
    required this.changeTracker,
    required this.supervisor,
    required this.runFuture,
    required this.logFile,
    required this.logSink,
  });

  static Future<_SupervisorFixture> create({
    AliveConfig config = const AliveConfig(
      device: 'USB-DEVICE',
      attachTimeout: Duration(seconds: 1),
      reconnectDebounce: Duration(milliseconds: 10),
    ),
    int attachFailures = 0,
    int attachHangs = 0,
    int runCrashes = 0,
  }) async {
    final project = await Directory.systemTemp.createTemp('alive-project-');
    await File('${project.path}/pubspec.yaml').writeAsString('''
name: fixture
environment:
  sdk: ^3.4.0
dependencies:
  flutter:
    sdk: flutter
''');
    await Directory('${project.path}/lib').create();
    await File('${project.path}/lib/main.dart')
        .writeAsString('void main() {}\n');
    await Directory('${project.path}/android/app').create(recursive: true);
    await File('${project.path}/android/app/build.gradle')
        .writeAsString('// initial\n');

    final harness = FakeFlutterHarness(usbDevice)
      ..attachFailuresRemaining = attachFailures
      ..attachHangsRemaining = attachHangs
      ..runCrashesRemaining = runCrashes;
    final logFile = File('${project.path}.log');
    // Closed by the fixture's async teardown.
    // ignore: close_sinks
    final logSink = logFile.openWrite();
    final changeTracker = ProjectChangeTracker(project.path);
    final supervisor = FlutterAliveSupervisor(
      flutter: const ExecutableCommand('flutter'),
      workingDirectory: project.path,
      config: config,
      runArguments: const [],
      reporter: AliveReporter(
        jsonMode: true,
        verbose: false,
        output: logSink,
        errorOutput: logSink,
      ),
      devicePicker: (devices) async => devices.firstOrNull,
      processStarter: harness.start,
      listenToProcessSignals: false,
      changeTracker: changeTracker,
      delay: (_) async {},
      identityResolver: DeviceIdentityResolver(
        commandRunner: (executable, arguments) async =>
            ProcessResult(1, 0, 'HARDWARE-SERIAL\n', ''),
      ),
    );
    final fixture = _SupervisorFixture(
      project: project,
      harness: harness,
      changeTracker: changeTracker,
      supervisor: supervisor,
      runFuture: supervisor.run(),
      logFile: logFile,
      logSink: logSink,
    );
    unawaited(fixture.runFuture.then((_) => fixture.completed = true));
    return fixture;
  }

  final Directory project;
  final FakeFlutterHarness harness;
  final ProjectChangeTracker changeTracker;
  final FlutterAliveSupervisor supervisor;
  final Future<int> runFuture;
  final File logFile;
  final IOSink logSink;
  bool completed = false;
  bool _disposed = false;

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    supervisor.requestStop();
    expect(await runFuture.timeout(const Duration(seconds: 5)), 0);
    await logSink.close();
    if (await logFile.exists()) {
      await logFile.delete();
    }
    await project.delete(recursive: true);
  }
}
