import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:yaml/yaml.dart';

import '../device/device_info.dart';

final class AliveConfig {
  const AliveConfig({
    this.flutterPath,
    this.device,
    this.appId,
    this.connection = DeviceConnection.both,
    this.attachTimeout = const Duration(seconds: 10),
    this.reconnectDebounce = const Duration(milliseconds: 750),
    this.maxRunnerRetries = 3,
    this.runnerStabilityWindow = const Duration(seconds: 30),
    this.daemonStabilityWindow = const Duration(seconds: 30),
    this.runArguments = const [],
  });

  final String? flutterPath;
  final String? device;
  final String? appId;
  final DeviceConnection connection;
  final Duration attachTimeout;
  final Duration reconnectDebounce;
  final int maxRunnerRetries;
  final Duration runnerStabilityWindow;
  final Duration daemonStabilityWindow;
  final List<String> runArguments;

  AliveConfig copyWith({
    String? flutterPath,
    String? device,
    String? appId,
    DeviceConnection? connection,
    Duration? attachTimeout,
    Duration? reconnectDebounce,
    int? maxRunnerRetries,
    Duration? runnerStabilityWindow,
    Duration? daemonStabilityWindow,
    List<String>? runArguments,
  }) {
    return AliveConfig(
      flutterPath: flutterPath ?? this.flutterPath,
      device: device ?? this.device,
      appId: appId ?? this.appId,
      connection: connection ?? this.connection,
      attachTimeout: attachTimeout ?? this.attachTimeout,
      reconnectDebounce: reconnectDebounce ?? this.reconnectDebounce,
      maxRunnerRetries: maxRunnerRetries ?? this.maxRunnerRetries,
      runnerStabilityWindow:
          runnerStabilityWindow ?? this.runnerStabilityWindow,
      daemonStabilityWindow:
          daemonStabilityWindow ?? this.daemonStabilityWindow,
      runArguments: runArguments ?? this.runArguments,
    );
  }

  static Future<AliveConfig> load({
    required String workingDirectory,
    String? explicitPath,
  }) async {
    final configPath =
        explicitPath ?? path.join(workingDirectory, '.flutter_alive.yaml');
    final file = File(configPath);
    if (!await file.exists()) {
      return const AliveConfig();
    }

    final document = loadYaml(await file.readAsString());
    if (document == null) {
      return const AliveConfig();
    }
    if (document is! YamlMap) {
      throw const FormatException('Flutter Alive config must be a YAML map.');
    }

    final connectionName = _stringValue(document, 'connection') ?? 'both';
    final connections = DeviceConnection.values.where(
      (value) => value.name == connectionName,
    );
    if (connections.isEmpty) {
      throw FormatException(
        'Invalid connection "$connectionName". Use attached, wireless, or both.',
      );
    }

    final attachSeconds = _intValue(document, 'attach_timeout_seconds') ?? 10;
    final debounceMs = _intValue(document, 'reconnect_debounce_ms') ?? 750;
    final retries = _intValue(document, 'max_runner_retries') ?? 3;
    final runnerStabilitySeconds =
        _intValue(document, 'runner_stability_seconds') ?? 30;
    final daemonStabilitySeconds =
        _intValue(document, 'daemon_stability_seconds') ?? 30;
    if (attachSeconds < 1 ||
        debounceMs < 0 ||
        retries < 0 ||
        runnerStabilitySeconds < 0 ||
        daemonStabilitySeconds < 0) {
      throw const FormatException(
        'Timeouts must be positive and retry count cannot be negative.',
      );
    }

    return AliveConfig(
      flutterPath: _stringValue(document, 'flutter'),
      device: _stringValue(document, 'device'),
      appId: _stringValue(document, 'app_id'),
      connection: connections.first,
      attachTimeout: Duration(seconds: attachSeconds),
      reconnectDebounce: Duration(milliseconds: debounceMs),
      maxRunnerRetries: retries,
      runnerStabilityWindow: Duration(seconds: runnerStabilitySeconds),
      daemonStabilityWindow: Duration(seconds: daemonStabilitySeconds),
      runArguments: _stringList(document, 'run_args'),
    );
  }

  static String? _stringValue(YamlMap map, String key) {
    final value = map[key];
    if (value == null) {
      return null;
    }
    if (value is! String) {
      throw FormatException('Config key "$key" must be a string.');
    }
    return value;
  }

  static int? _intValue(YamlMap map, String key) {
    final value = map[key];
    if (value == null) {
      return null;
    }
    if (value is! int) {
      throw FormatException('Config key "$key" must be an integer.');
    }
    return value;
  }

  static List<String> _stringList(YamlMap map, String key) {
    final value = map[key];
    if (value == null) {
      return const [];
    }
    if (value is! YamlList || value.any((item) => item is! String)) {
      throw FormatException('Config key "$key" must be a list of strings.');
    }
    return value.cast<String>().toList(growable: false);
  }
}
