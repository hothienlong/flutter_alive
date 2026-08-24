import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_alive/src/device/device_info.dart';
import 'package:flutter_alive/src/process/managed_process.dart';

final class FakeFlutterHarness {
  FakeFlutterHarness(this.initialDevice) : currentDevice = initialDevice;

  final DeviceInfo initialDevice;
  DeviceInfo? currentDevice;
  final List<List<String>> invocations = [];
  final List<FakeManagedProcess> sessions = [];
  final List<FakeManagedProcess> daemons = [];
  FakeManagedProcess? daemon;
  int attachFailuresRemaining = 0;
  int attachHangsRemaining = 0;
  int runCrashesRemaining = 0;

  Future<ManagedProcess> start(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required Map<String, String> environment,
  }) async {
    invocations.add(List<String>.from(arguments));
    if (arguments.contains('daemon')) {
      return _startDaemon();
    }
    if (arguments.contains('run')) {
      return _startSession('run');
    }
    if (arguments.contains('attach')) {
      return _startSession('attach');
    }
    throw StateError('Unexpected command: $executable ${arguments.join(' ')}');
  }

  Future<void> disconnect() async {
    final device = currentDevice;
    if (device == null) {
      return;
    }
    currentDevice = null;
    daemon?.emitEvent('device.removed', device.toJson());
    final active = sessions.lastOrNull;
    if (active != null) {
      active.emitEvent('app.log', {
        'appId': active.appId,
        'log': 'Lost connection to device.',
        'error': true,
      });
      active.emitEvent('app.stop', {'appId': active.appId});
      await active.exit(1);
    }
  }

  Future<void> loseRunnerConnectionWithoutDeviceEvent() async {
    final active = sessions.lastOrNull;
    if (active == null) {
      return;
    }
    active.emitEvent('app.log', {
      'appId': active.appId,
      'log': 'Lost connection to device.',
      'error': true,
    });
    await active.exit(0);
  }

  void reconnect(DeviceInfo device) {
    currentDevice = device;
    daemon?.emitEvent('device.added', device.toJson());
  }

  Future<void> switchConnection({
    required DeviceInfo from,
    required DeviceInfo to,
  }) async {
    currentDevice = to;
    daemon?.emitEvent('device.added', to.toJson());
    await Future<void>.delayed(const Duration(milliseconds: 20));
    daemon?.emitEvent('device.removed', from.toJson());
    final active = sessions.lastOrNull;
    if (active != null) {
      active.emitEvent('app.log', {
        'appId': active.appId,
        'log': 'Lost connection to device.',
        'error': true,
      });
      await active.exit(1);
    }
  }

  Future<void> crashDaemon([int exitCode = 1]) async {
    await daemon?.exit(exitCode);
  }

  Future<void> waitForSessionCount(int count) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (sessions.length < count) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException(
            'Expected $count sessions, found ${sessions.length}.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  FakeManagedProcess _startDaemon() {
    late final FakeManagedProcess process;
    process = FakeManagedProcess(onRequest: (request) async {
      final method = request['method'];
      final id = request['id'];
      if (id is! int || method is! String) {
        return;
      }
      switch (method) {
        case 'daemon.version':
          process.respond(id, '0.6.1');
        case 'device.enable':
          process.respond(id, null);
        case 'device.getDevices':
          process.respond(
            id,
            [if (currentDevice case final device?) device.toJson()],
          );
        case 'daemon.shutdown':
          process.respond(id, null);
          await process.exit(0);
      }
    });
    daemon = process;
    daemons.add(process);
    return process;
  }

  FakeManagedProcess _startSession(String mode) {
    late final FakeManagedProcess process;
    process = FakeManagedProcess(onRequest: (request) async {
      final method = request['method'];
      final id = request['id'];
      if (id is! int || method is! String) {
        return;
      }
      switch (method) {
        case 'app.restart':
          process.respond(id, {'code': 0, 'message': 'ok'});
        case 'app.stop':
        case 'app.detach':
          process.respond(id, true);
          await process.exit(0);
      }
    });
    sessions.add(process);
    if (mode == 'attach' && attachHangsRemaining > 0) {
      attachHangsRemaining -= 1;
      return process;
    }
    if (mode == 'attach' && attachFailuresRemaining > 0) {
      attachFailuresRemaining -= 1;
      Timer(const Duration(milliseconds: 10), () => process.exit(1));
      return process;
    }
    Timer(const Duration(milliseconds: 10), () {
      process.emitEvent('app.start', {
        'appId': process.appId,
        'deviceId': currentDevice?.id ?? initialDevice.id,
        'launchMode': mode,
        'supportsRestart': true,
        'mode': 'debug',
      });
      process.emitEvent('app.debugPort', {
        'appId': process.appId,
        'wsUri': 'ws://127.0.0.1:12345/ws',
      });
      process.emitEvent('app.started', {'appId': process.appId});
      if (mode == 'run' && runCrashesRemaining > 0) {
        runCrashesRemaining -= 1;
        Timer(const Duration(milliseconds: 10), () => process.exit(1));
      }
    });
    return process;
  }
}

final class FakeManagedProcess implements ManagedProcess {
  FakeManagedProcess({required this.onRequest}) : pid = _nextPid++ {
    stdin = IOSink(_InputConsumer(_handleInputLine));
  }

  static int _nextPid = 1000;

  final Future<void> Function(Map<String, Object?> request) onRequest;
  final StreamController<List<int>> _stdout = StreamController<List<int>>();
  final StreamController<List<int>> _stderr = StreamController<List<int>>();
  final Completer<int> _exitCode = Completer<int>();
  final List<Map<String, Object?>> requests = [];

  @override
  final int pid;

  final String appId = 'fake-app-${DateTime.now().microsecondsSinceEpoch}';

  @override
  late final IOSink stdin;

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    unawaited(exit(-15));
    return true;
  }

  void emitEvent(String name, Map<String, Object?> parameters) {
    _write([
      {'event': name, 'params': parameters},
    ]);
  }

  void respond(int id, Object? result) {
    _write([
      {'id': id, 'result': result},
    ]);
  }

  Future<void> exit(int code) async {
    if (_exitCode.isCompleted) {
      return;
    }
    _exitCode.complete(code);
    await _stdout.close();
    await _stderr.close();
    unawaited(stdin.close());
  }

  void _write(List<Map<String, Object?>> message) {
    if (!_stdout.isClosed) {
      _stdout.add(utf8.encode('${jsonEncode(message)}\n'));
    }
  }

  Future<void> _handleInputLine(String line) async {
    final decoded = jsonDecode(line);
    if (decoded is! List<Object?>) {
      return;
    }
    for (final item in decoded.whereType<Map<Object?, Object?>>()) {
      final request = item.map((key, value) => MapEntry(key.toString(), value));
      requests.add(request);
      await onRequest(request);
    }
  }
}

final class _InputConsumer implements StreamConsumer<List<int>> {
  _InputConsumer(this.onLine) {
    _subscription = _controller.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => unawaited(onLine(line)));
  }

  final Future<void> Function(String line) onLine;
  final StreamController<List<int>> _controller = StreamController<List<int>>();
  late final StreamSubscription<String> _subscription;

  @override
  Future<void> addStream(Stream<List<int>> stream) =>
      _controller.addStream(stream);

  @override
  Future<void> close() async {
    await _controller.close();
    await _subscription.cancel();
  }
}
