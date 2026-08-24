import 'dart:convert';
import 'dart:io';

import 'package:flutter_alive/src/cli/flutter_alive_cli.dart';
import 'package:flutter_alive/src/device/device_info.dart';
import 'package:flutter_alive/src/process/managed_process.dart';
import 'package:test/test.dart';

import '../fakes/fake_flutter_harness.dart';

void main() {
  late Directory project;
  late Directory previousDirectory;
  late File outputFile;
  late IOSink outputSink;

  setUp(() async {
    project = await Directory.systemTemp.createTemp('alive-cli-');
    previousDirectory = Directory.current;
    Directory.current = project;
    await File('${project.path}/pubspec.yaml').writeAsString('''
name: fixture
environment:
  sdk: ^3.4.0
dependencies:
  flutter:
    sdk: flutter
''');
    outputFile = File('${project.path}/output.log');
    outputSink = outputFile.openWrite();
  });

  tearDown(() async {
    await outputSink.close();
    Directory.current = previousDirectory;
    await project.delete(recursive: true);
  });

  test('prints help without starting Flutter', () async {
    final cli = FlutterAliveCli(output: outputSink, errorOutput: outputSink);

    expect(await cli.run(['--help']), 0);
    await outputSink.flush();
    expect(await outputFile.readAsString(), contains('flutter_alive devices'));
  });

  test('lists devices through the persistent daemon protocol', () async {
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
    final harness = FakeFlutterHarness(device);
    final cli = FlutterAliveCli(
      output: outputSink,
      errorOutput: outputSink,
      flutterResolver: ({required workingDirectory, configuredPath}) async =>
          const ExecutableCommand('flutter'),
      processStarter: harness.start,
      processResultRunner: _successfulProcessRun,
    );

    expect(await cli.run(['devices']), 0);
    await outputSink.flush();
    final output = await outputFile.readAsString();
    expect(output, contains('Test Phone'));
    expect(output, contains('phone-1'));
  });

  test('doctor validates Flutter, project, daemon, adb, and Xcode tools',
      () async {
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
    final harness = FakeFlutterHarness(device);
    final cli = FlutterAliveCli(
      output: outputSink,
      errorOutput: outputSink,
      flutterResolver: ({required workingDirectory, configuredPath}) async =>
          const ExecutableCommand('flutter'),
      processStarter: harness.start,
      processResultRunner: _successfulProcessRun,
    );

    expect(await cli.run(['doctor']), 0);
    await outputSink.flush();
    final output = await outputFile.readAsString();
    expect(output, contains('[ok] Flutter executable'));
    expect(output, contains('[ok] Flutter daemon protocol: 0.6.1'));
    expect(output, contains('[ok] ADB'));
  });

  test('init creates an optional config file', () async {
    final cli = FlutterAliveCli(output: outputSink, errorOutput: outputSink);

    expect(await cli.run(['init']), 0);

    final config = File('${project.path}/.flutter_alive.yaml');
    expect(await config.exists(), isTrue);
    expect(await config.readAsString(), contains('attach_timeout_seconds: 10'));
  });

  test('rejects unknown Flutter Alive options', () async {
    final cli = FlutterAliveCli(output: outputSink, errorOutput: outputSink);

    expect(await cli.run(['--alive-unknown']), 64);
    await outputSink.flush();
    expect(await outputFile.readAsString(),
        contains('Unknown Flutter Alive option'));
  });

  test('CLI options override project configuration', () async {
    await File('${project.path}/.flutter_alive.yaml').writeAsString('''
flutter: /configured/flutter
connection: wireless
''');
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
    final harness = FakeFlutterHarness(device);
    String? resolvedFlutterPath;
    final cli = FlutterAliveCli(
      output: outputSink,
      errorOutput: outputSink,
      flutterResolver: ({required workingDirectory, configuredPath}) async {
        resolvedFlutterPath = configuredPath;
        return const ExecutableCommand('flutter');
      },
      processStarter: harness.start,
      processResultRunner: _successfulProcessRun,
    );

    expect(
      await cli.run([
        'devices',
        '--alive-flutter=/cli/flutter',
        '--alive-connection=attached',
      ]),
      0,
    );
    await outputSink.flush();

    expect(resolvedFlutterPath, '/cli/flutter');
    expect(await outputFile.readAsString(), contains('phone-1'));
  });

  test('rejects Flutter versions older than 3.22', () async {
    final cli = FlutterAliveCli(
      output: outputSink,
      errorOutput: outputSink,
      flutterResolver: ({required workingDirectory, configuredPath}) async =>
          const ExecutableCommand('flutter'),
      processResultRunner: (
        executable,
        arguments, {
        workingDirectory,
      }) async =>
          ProcessResult(
        1,
        0,
        jsonEncode({'frameworkVersion': '3.19.6'}),
        '',
      ),
    );

    expect(await cli.run(['devices']), 1);
    await outputSink.flush();
    expect(await outputFile.readAsString(), contains('requires Flutter 3.22'));
  });
}

Future<ProcessResult> _successfulProcessRun(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
}) async {
  if (arguments.contains('--version') && arguments.contains('--machine')) {
    return ProcessResult(
      1,
      0,
      jsonEncode({'frameworkVersion': '3.27.4'}),
      '',
    );
  }
  if (executable == 'adb') {
    return ProcessResult(2, 0, 'Android Debug Bridge version 1.0.41\n', '');
  }
  if (executable == 'xcrun') {
    return ProcessResult(3, 0, '518.33\n', '');
  }
  return ProcessResult(4, 0, '', '');
}
