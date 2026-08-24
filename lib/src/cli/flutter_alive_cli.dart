import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:yaml/yaml.dart';

import '../config/alive_config.dart';
import '../daemon/flutter_daemon_client.dart';
import '../dap/flutter_alive_dap_bridge.dart';
import '../device/device_info.dart';
import '../process/flutter_executable_resolver.dart';
import '../process/managed_process.dart';
import '../supervisor/flutter_alive_supervisor.dart';
import '../ui/alive_reporter.dart';

const String flutterAliveVersion = '0.1.0-dev.1';

enum _CliCommand { run, devices, doctor, init, debugAdapter, help, version }

typedef FlutterCommandResolver = Future<ExecutableCommand> Function({
  required String workingDirectory,
  String? configuredPath,
});

typedef ProcessResultRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
});

Future<ProcessResult> runResultProcess(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
}) =>
    Process.run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
    );

final class FlutterAliveCli {
  FlutterAliveCli({
    IOSink? output,
    IOSink? errorOutput,
    FlutterExecutableResolver? executableResolver,
    FlutterCommandResolver? flutterResolver,
    Stream<List<int>>? input,
    this.processResultRunner = runResultProcess,
    this.processStarter = startIoProcess,
  })  : output = output ?? stdout,
        errorOutput = errorOutput ?? stderr,
        input = input ?? stdin,
        flutterResolver = flutterResolver ??
            (executableResolver ?? const FlutterExecutableResolver()).resolve;

  final IOSink output;
  final IOSink errorOutput;
  final Stream<List<int>> input;
  final FlutterCommandResolver flutterResolver;
  final ProcessResultRunner processResultRunner;
  final ProcessStarter processStarter;

  Future<int> run(List<String> arguments) async {
    try {
      final parsed = _ParsedArguments.parse(arguments);
      if (parsed.command == _CliCommand.help) {
        _printHelp();
        return 0;
      }
      if (parsed.command == _CliCommand.version) {
        output.writeln('flutter_alive $flutterAliveVersion');
        return 0;
      }

      final workingDirectory = Directory.current.absolute.path;
      final fileConfig = await AliveConfig.load(
        workingDirectory: workingDirectory,
        explicitPath: parsed.configPath,
      );
      final config = fileConfig.copyWith(
        flutterPath: parsed.flutterPath,
        device: parsed.device,
        appId: parsed.appId,
        connection: parsed.connection,
        attachTimeout: parsed.attachTimeout,
        runArguments: [
          ...fileConfig.runArguments,
          ...parsed.flutterArguments,
        ],
      );
      final flutter = await flutterResolver(
        workingDirectory: workingDirectory,
        configuredPath: config.flutterPath,
      );
      final reporter = AliveReporter(
        jsonMode: parsed.jsonMode,
        verbose: parsed.verbose,
        output: output,
        errorOutput: errorOutput,
      );

      return await (switch (parsed.command) {
        _CliCommand.run => _runSupervisor(
            flutter: flutter,
            workingDirectory: workingDirectory,
            config: config,
            attachEnabled: !parsed.noAttach,
            reporter: reporter,
          ),
        _CliCommand.devices => _listDevices(
            flutter: flutter,
            workingDirectory: workingDirectory,
            config: config,
            reporter: reporter,
          ),
        _CliCommand.doctor => _doctor(
            flutter: flutter,
            workingDirectory: workingDirectory,
            reporter: reporter,
          ),
        _CliCommand.init => _initializeConfig(workingDirectory),
        _CliCommand.debugAdapter => _runDebugAdapter(
            flutter: flutter,
            workingDirectory: workingDirectory,
            config: config,
            attachEnabled: !parsed.noAttach,
          ),
        _CliCommand.help || _CliCommand.version => Future<int>.value(0),
      });
    } on FormatException catch (error) {
      errorOutput.writeln('Error: ${error.message}');
      errorOutput.writeln('Run flutter_alive --help for usage.');
      return 64;
    } on Object catch (error) {
      errorOutput.writeln('Error: $error');
      return 1;
    }
  }

  Future<int> _runSupervisor({
    required ExecutableCommand flutter,
    required String workingDirectory,
    required AliveConfig config,
    required bool attachEnabled,
    required AliveReporter reporter,
  }) async {
    await _validateProject(workingDirectory);
    await _validateFlutter(flutter, workingDirectory);
    final supervisor = FlutterAliveSupervisor(
      flutter: flutter,
      workingDirectory: workingDirectory,
      config: config,
      runArguments: config.runArguments,
      reporter: reporter,
      attachEnabled: attachEnabled,
      processStarter: processStarter,
      devicePicker: (devices) => _pickDevice(devices, reporter),
    );
    return supervisor.run();
  }

  Future<int> _listDevices({
    required ExecutableCommand flutter,
    required String workingDirectory,
    required AliveConfig config,
    required AliveReporter reporter,
  }) async {
    await _validateFlutter(flutter, workingDirectory);
    final daemon = await FlutterDaemonClient.start(
      flutter: flutter,
      workingDirectory: workingDirectory,
      processStarter: processStarter,
      environment: Platform.environment,
      onLog: reporter.verbose ? reporter.log : null,
    );
    try {
      final devices = await daemon.getDevices();
      final filtered = devices.where(
        (device) =>
            device.isSupportedPhysicalMobile &&
            device.isAllowedBy(config.connection),
      );
      if (reporter.jsonMode) {
        for (final device in filtered) {
          reporter.device('found', device);
        }
      } else {
        final list = filtered.toList(growable: false);
        if (list.isEmpty) {
          output.writeln('No Flutter devices found.');
        }
        for (final device in list) {
          output.writeln(
            '${device.name} • ${device.id} • ${device.platform} • ${device.connectionInterface}',
          );
        }
      }
      return 0;
    } finally {
      await daemon.shutdown();
    }
  }

  Future<int> _runDebugAdapter({
    required ExecutableCommand flutter,
    required String workingDirectory,
    required AliveConfig config,
    required bool attachEnabled,
  }) async {
    await _validateProject(workingDirectory);
    await _validateFlutter(flutter, workingDirectory);
    final bridge = FlutterAliveDapBridge(
      flutter: flutter,
      workingDirectory: workingDirectory,
      input: input,
      output: output,
      errorOutput: errorOutput,
      processStarter: processStarter,
      environment: Platform.environment,
      attachTimeout: config.attachTimeout,
      attachEnabled: attachEnabled,
    );
    return bridge.run();
  }

  Future<int> _doctor({
    required ExecutableCommand flutter,
    required String workingDirectory,
    required AliveReporter reporter,
  }) async {
    var failures = 0;
    Future<void> check(
      String name,
      Future<String> Function() operation,
    ) async {
      try {
        final detail = await operation();
        reporter.log('[ok] $name${detail.isEmpty ? '' : ': $detail'}');
      } on Object catch (error) {
        failures += 1;
        reporter.log('[fail] $name: $error', error: true);
      }
    }

    await check('Flutter executable', () async {
      return _flutterVersion(flutter, workingDirectory);
    });
    await check('Flutter project', () async {
      await _validateProject(workingDirectory);
      return workingDirectory;
    });
    await check('Flutter daemon protocol', () async {
      final daemon = await FlutterDaemonClient.start(
        flutter: flutter,
        workingDirectory: workingDirectory,
        processStarter: processStarter,
        environment: Platform.environment,
      );
      try {
        return daemon.protocolVersion;
      } finally {
        await daemon.shutdown();
      }
    });
    await check('ADB', () async {
      final result = await processResultRunner('adb', ['version']);
      if (result.exitCode != 0) {
        throw StateError(result.stderr.toString().trim());
      }
      return result.stdout.toString().split('\n').first.trim();
    });
    if (Platform.isMacOS) {
      await check('Xcode device tooling', () async {
        final result = await processResultRunner(
          'xcrun',
          ['devicectl', '--version'],
        );
        if (result.exitCode != 0) {
          throw StateError(result.stderr.toString().trim());
        }
        return result.stdout.toString().trim();
      });
    }
    return failures == 0 ? 0 : 1;
  }

  Future<int> _initializeConfig(String workingDirectory) async {
    final file = File(path.join(workingDirectory, '.flutter_alive.yaml'));
    if (await file.exists()) {
      throw const FormatException('.flutter_alive.yaml already exists.');
    }
    await file.writeAsString('''# Flutter Alive project configuration
connection: both
attach_timeout_seconds: 10
reconnect_debounce_ms: 750
max_runner_retries: 3
runner_stability_seconds: 30
daemon_stability_seconds: 30
run_args: []
''');
    output.writeln('Created ${file.path}');
    return 0;
  }

  Future<DeviceInfo?> _pickDevice(
    List<DeviceInfo> devices,
    AliveReporter reporter,
  ) async {
    if (!stdin.hasTerminal) {
      throw const FormatException(
        'Multiple devices found. Pass -d <device-id> in non-interactive mode.',
      );
    }
    output.writeln('Select a device:');
    for (var index = 0; index < devices.length; index += 1) {
      final device = devices[index];
      output.writeln('  ${index + 1}. ${device.name} (${device.id})');
    }
    output.write('Device: ');
    final input = stdin.readLineSync();
    final selectedIndex = int.tryParse(input ?? '');
    if (selectedIndex == null ||
        selectedIndex < 1 ||
        selectedIndex > devices.length) {
      reporter.warning('No device selected.');
      return null;
    }
    return devices[selectedIndex - 1];
  }

  Future<void> _validateFlutter(
    ExecutableCommand flutter,
    String workingDirectory,
  ) async {
    final version = await _flutterVersion(flutter, workingDirectory);
    final components = version
        .split(RegExp(r'[-+]'))
        .first
        .split('.')
        .map(int.tryParse)
        .toList(growable: false);
    final major = components.isNotEmpty ? components[0] : null;
    final minor = components.length > 1 ? components[1] : null;
    if (major == null ||
        minor == null ||
        major < 3 ||
        major == 3 && minor < 22) {
      throw StateError(
        'Flutter $version is unsupported. Flutter Alive requires Flutter 3.22 or newer.',
      );
    }
  }

  Future<String> _flutterVersion(
    ExecutableCommand flutter,
    String workingDirectory,
  ) async {
    final result = await _runFlutter(
      flutter,
      ['--version', '--machine', '--suppress-analytics'],
      workingDirectory,
    );
    if (result.exitCode != 0) {
      throw StateError(
        'Flutter executable failed: ${result.stderr.toString().trim()}',
      );
    }
    final decoded = jsonDecode(result.stdout.toString());
    if (decoded is! Map<Object?, Object?>) {
      throw const FormatException('Unexpected Flutter version output.');
    }
    return decoded['frameworkVersion']?.toString() ?? 'unknown';
  }

  Future<ProcessResult> _runFlutter(
    ExecutableCommand flutter,
    List<String> arguments,
    String workingDirectory,
  ) {
    return processResultRunner(
      flutter.executable,
      flutter.argumentsFor(arguments),
      workingDirectory: workingDirectory,
    );
  }

  Future<void> _validateProject(String workingDirectory) async {
    final pubspec = File(path.join(workingDirectory, 'pubspec.yaml'));
    if (!await pubspec.exists()) {
      throw const FormatException(
        'Run flutter_alive from a Flutter project containing pubspec.yaml.',
      );
    }
    final document = loadYaml(await pubspec.readAsString());
    if (document is! YamlMap) {
      throw const FormatException('pubspec.yaml is not a YAML map.');
    }
    final dependencies = document['dependencies'];
    final devDependencies = document['dev_dependencies'];
    final hasFlutter =
        dependencies is YamlMap && dependencies.containsKey('flutter');
    final hasFlutterDev = devDependencies is YamlMap &&
        devDependencies.containsKey('flutter_test');
    if (!hasFlutter && !hasFlutterDev) {
      throw const FormatException('pubspec.yaml is not a Flutter project.');
    }
  }

  void _printHelp() {
    output.writeln('''Flutter Alive $flutterAliveVersion

A persistent development supervisor for Flutter devices.

Usage:
  flutter_alive [run] -d <device> [flutter run arguments...]
  flutter_alive devices
  flutter_alive doctor
  flutter_alive init
  flutter_alive debug-adapter

Flutter Alive options:
  --alive-flutter <path>          Flutter binary or SDK path
  --alive-app-id <id>             Android package or iOS bundle identifier
  --alive-attach-timeout <secs>   Attach timeout (default: 10)
  --alive-connection <mode>       attached, wireless, or both
  --alive-config <path>           Config file path
  --alive-no-attach               Always launch a fresh app after reconnect
  --alive-json                    Emit JSON Lines events
  --alive-verbose                 Include daemon diagnostics
  -d, --device-id <id>            Target device
  -h, --help                      Show help
  --version                       Show version

All other arguments are forwarded to flutter run.
''');
  }
}

final class _ParsedArguments {
  const _ParsedArguments({
    required this.command,
    required this.flutterArguments,
    required this.jsonMode,
    required this.verbose,
    required this.noAttach,
    this.flutterPath,
    this.device,
    this.appId,
    this.attachTimeout,
    this.connection,
    this.configPath,
  });

  factory _ParsedArguments.parse(List<String> arguments) {
    var command = _CliCommand.run;
    var startIndex = 0;
    if (arguments.isNotEmpty) {
      command = switch (arguments.first) {
        'run' => _CliCommand.run,
        'devices' => _CliCommand.devices,
        'doctor' => _CliCommand.doctor,
        'init' => _CliCommand.init,
        'debug-adapter' => _CliCommand.debugAdapter,
        'help' || '-h' || '--help' => _CliCommand.help,
        '--version' => _CliCommand.version,
        _ => _CliCommand.run,
      };
      if ({'run', 'devices', 'doctor', 'init', 'debug-adapter', 'help'}
          .contains(arguments.first)) {
        startIndex = 1;
      } else if (arguments.first == '-h' ||
          arguments.first == '--help' ||
          arguments.first == '--version') {
        startIndex = 1;
      }
    }

    String? flutterPath;
    String? device;
    String? appId;
    Duration? attachTimeout;
    DeviceConnection? connection;
    String? configPath;
    var jsonMode = false;
    var verbose = false;
    var noAttach = false;
    final flutterArguments = <String>[];

    for (var index = startIndex; index < arguments.length; index += 1) {
      final argument = arguments[index];
      String nextValue(String option) {
        if (index + 1 >= arguments.length) {
          throw FormatException('Missing value for $option.');
        }
        index += 1;
        return arguments[index];
      }

      if (argument == '--alive-json') {
        jsonMode = true;
      } else if (argument == '--alive-verbose') {
        verbose = true;
      } else if (argument == '--alive-no-attach') {
        noAttach = true;
      } else if (argument == '--alive-flutter') {
        flutterPath = nextValue(argument);
      } else if (argument.startsWith('--alive-flutter=')) {
        flutterPath = argument.substring('--alive-flutter='.length);
      } else if (argument == '--alive-app-id') {
        appId = nextValue(argument);
      } else if (argument.startsWith('--alive-app-id=')) {
        appId = argument.substring('--alive-app-id='.length);
      } else if (argument == '--alive-config') {
        configPath = nextValue(argument);
      } else if (argument.startsWith('--alive-config=')) {
        configPath = argument.substring('--alive-config='.length);
      } else if (argument == '--alive-attach-timeout') {
        attachTimeout = _parseDuration(nextValue(argument), argument);
      } else if (argument.startsWith('--alive-attach-timeout=')) {
        attachTimeout = _parseDuration(
          argument.substring('--alive-attach-timeout='.length),
          '--alive-attach-timeout',
        );
      } else if (argument == '--alive-connection') {
        connection = _parseConnection(nextValue(argument));
      } else if (argument.startsWith('--alive-connection=')) {
        connection = _parseConnection(
          argument.substring('--alive-connection='.length),
        );
      } else if (argument == '-d' || argument == '--device-id') {
        device = nextValue(argument);
      } else if (argument.startsWith('--device-id=')) {
        device = argument.substring('--device-id='.length);
      } else if (argument.startsWith('--alive-')) {
        throw FormatException('Unknown Flutter Alive option "$argument".');
      } else {
        flutterArguments.add(argument);
      }
    }

    return _ParsedArguments(
      command: command,
      flutterArguments: flutterArguments,
      jsonMode: jsonMode,
      verbose: verbose,
      noAttach: noAttach,
      flutterPath: flutterPath,
      device: device,
      appId: appId,
      attachTimeout: attachTimeout,
      connection: connection,
      configPath: configPath,
    );
  }

  final _CliCommand command;
  final List<String> flutterArguments;
  final bool jsonMode;
  final bool verbose;
  final bool noAttach;
  final String? flutterPath;
  final String? device;
  final String? appId;
  final Duration? attachTimeout;
  final DeviceConnection? connection;
  final String? configPath;

  static Duration _parseDuration(String value, String option) {
    final seconds = int.tryParse(value);
    if (seconds == null || seconds < 1) {
      throw FormatException('$option must be a positive integer.');
    }
    return Duration(seconds: seconds);
  }

  static DeviceConnection _parseConnection(String value) {
    final matches = DeviceConnection.values.where((item) => item.name == value);
    if (matches.isEmpty) {
      throw FormatException(
        'Invalid connection "$value". Use attached, wireless, or both.',
      );
    }
    return matches.first;
  }
}
