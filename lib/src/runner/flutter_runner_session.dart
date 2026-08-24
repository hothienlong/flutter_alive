import 'dart:async';
import 'dart:io';

import '../process/managed_process.dart';
import '../protocol/machine_protocol.dart';

enum RunnerMode { run, attach }

final class FlutterRunnerSession {
  FlutterRunnerSession._({
    required this.mode,
    required this.deviceId,
    required this.process,
  });

  static Future<FlutterRunnerSession> start({
    required RunnerMode mode,
    required ExecutableCommand flutter,
    required String deviceId,
    required String workingDirectory,
    required List<String> runArguments,
    required ProcessStarter processStarter,
    required Map<String, String> environment,
    String? appId,
    void Function(String line, {bool error})? onLog,
  }) async {
    final commandArguments = mode == RunnerMode.run
        ? _runArguments(deviceId, runArguments)
        : _attachArguments(deviceId, runArguments, appId);
    final process = await processStarter(
      flutter.executable,
      flutter.argumentsFor(commandArguments),
      workingDirectory: workingDirectory,
      environment: environment,
    );
    final session = FlutterRunnerSession._(
      mode: mode,
      deviceId: deviceId,
      process: process,
    );
    final connection = MachineConnection(
      stdout: process.stdout,
      stderr: process.stderr,
      writeLine: (line) => process.stdin.writeln(line),
      exitCode: process.exitCode,
      onUnhandledLine: (line) {
        onLog?.call(line, error: true);
        session._inspectLog(line);
      },
    );
    session.connection = connection;
    session._eventSubscription = connection.events.listen((event) {
      session._handleEvent(event, onLog);
    });
    unawaited(process.exitCode.then(session._handleExit));
    return session;
  }

  final RunnerMode mode;
  final String deviceId;
  final ManagedProcess process;
  late final MachineConnection connection;
  late final StreamSubscription<MachineEvent> _eventSubscription;
  final Completer<void> _started = Completer<void>();
  String? _appId;
  String? _debugUri;
  String? _stopError;
  bool _lostConnection = false;
  bool _closing = false;

  String? get appId => _appId;
  String? get debugUri => _debugUri;
  String? get stopError => _stopError;
  bool get lostConnection => _lostConnection;
  Future<int> get exitCode => process.exitCode;

  Future<void> waitUntilStarted({Duration? timeout}) async {
    final wait = Future.any<void>([
      _started.future,
      process.exitCode.then<void>((code) {
        throw StateError(
          '${mode.name} process exited with code $code before the app started.',
        );
      }),
    ]);
    if (timeout == null) {
      await wait;
    } else {
      await wait.timeout(timeout);
    }
  }

  Future<bool> reload({bool fullRestart = false}) async {
    final currentAppId = _appId;
    if (currentAppId == null) {
      return false;
    }
    try {
      final result = await connection.request('app.restart', {
        'appId': currentAppId,
        'fullRestart': fullRestart,
        'pause': false,
        'reason':
            fullRestart ? 'flutter_alive.restart' : 'flutter_alive.reload',
        'debounce': true,
      });
      if (result is Map<Object?, Object?>) {
        return result['code'] == 0;
      }
      return true;
    } on Object {
      return false;
    }
  }

  Future<void> stop() => _closeWithRequest('app.stop');

  Future<void> detach() => _closeWithRequest('app.detach');

  Future<void> killLocal() async {
    if (_closing) {
      return;
    }
    _closing = true;
    process.kill();
    try {
      await process.exitCode.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
    }
    await _eventSubscription.cancel();
    await connection.close();
  }

  Future<void> _closeWithRequest(String method) async {
    if (_closing) {
      return;
    }
    _closing = true;
    final currentAppId = _appId;
    if (currentAppId != null) {
      try {
        await connection.request(
          method,
          {'appId': currentAppId},
          const Duration(seconds: 2),
        );
      } on Object {
        process.kill();
      }
    } else {
      process.kill();
    }
    try {
      await process.exitCode.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
    }
    await _eventSubscription.cancel();
    await connection.close();
  }

  void _handleEvent(
    MachineEvent event,
    void Function(String line, {bool error})? onLog,
  ) {
    switch (event.name) {
      case 'app.start':
        _appId = event.parameters['appId'] as String?;
      case 'app.debugPort':
        _debugUri = event.parameters['wsUri'] as String?;
      case 'app.started':
        if (!_started.isCompleted) {
          _started.complete();
        }
      case 'app.stop':
        final error = event.parameters['error'];
        if (error != null) {
          _stopError = error.toString();
          _inspectLog(_stopError ?? '');
        }
      case 'app.log':
        final log = event.parameters['log'];
        if (log is String) {
          final error = event.parameters['error'] as bool? ?? false;
          onLog?.call(log, error: error);
          _inspectLog(log);
        }
    }
  }

  void _inspectLog(String line) {
    final normalized = line.toLowerCase();
    if (normalized.contains('lost connection to device') ||
        normalized.contains('device disconnected')) {
      _lostConnection = true;
    }
  }

  void _handleExit(int code) {
    if (!_started.isCompleted && !_closing) {
      _started.completeError(
        StateError('${mode.name} process exited with code $code.'),
      );
    }
  }

  static List<String> _runArguments(
    String deviceId,
    List<String> arguments,
  ) {
    return [
      'run',
      '--machine',
      '--suppress-analytics',
      '--no-version-check',
      '-d',
      deviceId,
      ..._withoutManagedArguments(arguments),
    ];
  }

  static List<String> _attachArguments(
    String deviceId,
    List<String> arguments,
    String? appId,
  ) {
    return [
      'attach',
      '--machine',
      '--suppress-analytics',
      '--no-version-check',
      '-d',
      deviceId,
      if (appId != null && appId.isNotEmpty) '--app-id=$appId',
      ..._attachCompatibleArguments(_withoutManagedArguments(arguments)),
    ];
  }

  static List<String> _withoutManagedArguments(List<String> arguments) {
    final output = <String>[];
    for (var index = 0; index < arguments.length; index += 1) {
      final argument = arguments[index];
      if (argument == '--machine' ||
          argument == '--suppress-analytics' ||
          argument == '--no-version-check') {
        continue;
      }
      if (argument == '-d' || argument == '--device-id') {
        index += 1;
        continue;
      }
      if (argument.startsWith('--device-id=')) {
        continue;
      }
      output.add(argument);
    }
    return output;
  }

  static List<String> _attachCompatibleArguments(List<String> arguments) {
    const flags = {
      '--debug',
      '--profile',
      '--track-widget-creation',
      '--no-track-widget-creation',
      '--dds',
      '--no-dds',
    };
    const valuedOptions = {
      '-t',
      '--target',
      '--dart-define',
      '--dart-define-from-file',
      '--device-user',
      '--device-vmservice-port',
      '--host-vmservice-port',
      '--dds-port',
    };
    final output = <String>[];
    for (var index = 0; index < arguments.length; index += 1) {
      final argument = arguments[index];
      if (flags.contains(argument)) {
        output.add(argument);
        continue;
      }
      if (valuedOptions.contains(argument)) {
        output.add(argument);
        if (index + 1 < arguments.length) {
          index += 1;
          output.add(arguments[index]);
        }
        continue;
      }
      if (valuedOptions.any((option) => argument.startsWith('$option='))) {
        output.add(argument);
      }
    }
    return output;
  }
}
