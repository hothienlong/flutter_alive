import 'dart:async';
import 'dart:io';

import 'package:flutter_alive/src/dap/dap_protocol.dart';
import 'package:flutter_alive/src/dap/flutter_alive_dap_bridge.dart';
import 'package:flutter_alive/src/device/device_identity_resolver.dart';
import 'package:flutter_alive/src/device/device_info.dart';
import 'package:flutter_alive/src/process/managed_process.dart';
import 'package:test/test.dart';

import '../fakes/fake_flutter_harness.dart';

void main() {
  test('keeps the outer DAP session and replays breakpoints after reconnect',
      () async {
    final project = await Directory.systemTemp.createTemp('alive-dap-');
    addTearDown(() => project.delete(recursive: true));
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
    final flutterHarness = FakeFlutterHarness(usb);
    final processStarter = _BridgeProcessStarter(flutterHarness);
    final editorInput = StreamController<List<int>>();
    // Closed through editorOutputSink.
    // ignore: close_sinks
    final editorOutput = StreamController<List<int>>();
    final editorOutputSink = IOSink(_ControllerConsumer(editorOutput));
    // Closed through errorSink.
    // ignore: close_sinks
    final errorController = StreamController<List<int>>();
    final errorSink = IOSink(_ControllerConsumer(errorController));
    final errorSubscription = errorController.stream.listen((_) {});
    final bridge = FlutterAliveDapBridge(
      flutter: const ExecutableCommand('flutter'),
      workingDirectory: project.path,
      input: editorInput.stream,
      output: editorOutputSink,
      errorOutput: errorSink,
      processStarter: processStarter.start,
      environment: const {},
      attachTimeout: const Duration(seconds: 1),
      delay: (_) async {},
      identityResolver: DeviceIdentityResolver(
        commandRunner: (executable, arguments) async =>
            ProcessResult(1, 0, 'HARDWARE-SERIAL\n', ''),
      ),
    );
    final runFuture = bridge.run();
    final editor = DapProtocolChannel(
      input: editorOutput.stream,
      writeBytes: editorInput.add,
    );
    final received = <Map<String, Object?>>[];
    final receivedSubscription = editor.messages.listen(received.add);

    editor.send({
      'seq': 1,
      'type': 'request',
      'command': 'initialize',
      'arguments': {'adapterID': 'flutter_alive'},
    });
    await _waitUntil(
      () => received.any(
        (message) =>
            message['type'] == 'event' && message['event'] == 'initialized',
      ),
      'the initial adapter to initialize',
    );
    editor
      ..send({
        'seq': 2,
        'type': 'request',
        'command': 'setBreakpoints',
        'arguments': {
          'source': {'path': '${project.path}/lib/main.dart'},
          'breakpoints': [
            {'line': 1},
          ],
        },
      })
      ..send({
        'seq': 3,
        'type': 'request',
        'command': 'configurationDone',
      })
      ..send({
        'seq': 4,
        'type': 'request',
        'command': 'launch',
        'arguments': {
          'program': 'lib/main.dart',
          'cwd': project.path,
          'deviceId': usb.id,
          'toolArgs': ['--flavor', 'staging'],
        },
      });
    await _waitForResponse(received, 4);
    final firstAdapter = processStarter.adapters.single;
    expect(
      firstAdapter.request('launch')['arguments'],
      containsPair('toolArgs', containsAllInOrder(['-d', usb.id])),
    );
    firstAdapter.sendReverseRequest('runInTerminal');
    await _waitUntil(
      () => received.any(
        (message) =>
            message['type'] == 'request' &&
            message['command'] == 'runInTerminal',
      ),
      'a child reverse request',
    );
    final reverseRequest = received.lastWhere(
      (message) =>
          message['type'] == 'request' && message['command'] == 'runInTerminal',
    );
    editor.send({
      'seq': 50,
      'type': 'response',
      'request_seq': reverseRequest['seq'],
      'success': true,
      'command': 'runInTerminal',
      'body': {'processId': 123},
    });
    await _waitUntil(
      () => firstAdapter.responses.any(
        (response) => response['request_seq'] == firstAdapter.lastReverseSeq,
      ),
      'the reverse response to reach the child adapter',
    );

    await flutterHarness.disconnect();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await firstAdapter.terminateForDeviceLoss();
    flutterHarness.reconnect(wireless);

    await _waitUntil(
      () => processStarter.adapters.length >= 2,
      'a replacement Flutter debug adapter',
    );
    final secondAdapter = processStarter.adapters[1];
    await _waitUntil(
      () => secondAdapter.hasRequest('attach'),
      'the replacement adapter to attach',
    );
    expect(secondAdapter.hasRequest('setBreakpoints'), isTrue);
    final attachArguments =
        secondAdapter.request('attach')['arguments'] as Map<String, Object?>;
    expect(
      attachArguments['toolArgs'],
      containsAllInOrder(['-d', wireless.id]),
    );
    expect(
      received.where((message) => message['event'] == 'terminated'),
      isEmpty,
    );
    await _waitUntil(
      () => received.any(
        (message) =>
            message['event'] == 'output' &&
            message.toString().contains('Reattached'),
      ),
      'a reattached status event',
    );

    editor.send({
      'seq': 5,
      'type': 'request',
      'command': 'disconnect',
      'arguments': {'terminateDebuggee': true},
    });
    expect(await runFuture.timeout(const Duration(seconds: 5)), 0);

    await receivedSubscription.cancel();
    await editor.close();
    await editorInput.close();
    await editorOutputSink.close();
    await errorSink.close();
    await errorSubscription.cancel();
  });
}

Future<Map<String, Object?>> _waitForResponse(
  List<Map<String, Object?>> messages,
  int requestSeq,
) async {
  await _waitUntil(
    () => messages.any(
      (message) =>
          message['type'] == 'response' && message['request_seq'] == requestSeq,
    ),
    'DAP response for request $requestSeq',
  );
  return messages.firstWhere(
    (message) =>
        message['type'] == 'response' && message['request_seq'] == requestSeq,
  );
}

Future<void> _waitUntil(bool Function() condition, String description) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Timed out waiting for $description.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

final class _BridgeProcessStarter {
  _BridgeProcessStarter(this.flutterHarness);

  final FakeFlutterHarness flutterHarness;
  final List<_FakeDapProcess> adapters = [];

  Future<ManagedProcess> start(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required Map<String, String> environment,
  }) async {
    if (arguments.contains('daemon')) {
      return flutterHarness.start(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment,
      );
    }
    if (arguments.contains('debug-adapter')) {
      final adapter = _FakeDapProcess();
      adapters.add(adapter);
      return adapter;
    }
    throw StateError('Unexpected process: $executable ${arguments.join(' ')}');
  }
}

final class _FakeDapProcess implements ManagedProcess {
  _FakeDapProcess() : pid = _nextPid++ {
    // Closed by _exit when the fake adapter terminates.
    // ignore: close_sinks
    stdin = IOSink(_ControllerConsumer(_input));
    _channel = DapProtocolChannel(
      input: _input.stream,
      writeBytes: _stdout.add,
    );
    _subscription = _channel.messages.listen(_handleRequest);
  }

  static int _nextPid = 5000;
  // Closed through stdin when the fake process exits.
  // ignore: close_sinks
  final StreamController<List<int>> _input = StreamController<List<int>>();
  final StreamController<List<int>> _stdout = StreamController<List<int>>();
  final StreamController<List<int>> _stderr = StreamController<List<int>>();
  final Completer<int> _exitCode = Completer<int>();
  final List<Map<String, Object?>> requests = [];
  final List<Map<String, Object?>> responses = [];
  late final DapProtocolChannel _channel;
  late final StreamSubscription<Map<String, Object?>> _subscription;
  int _seq = 1;
  int? lastReverseSeq;

  @override
  final int pid;

  @override
  late final IOSink stdin;

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  Future<int> get exitCode => _exitCode.future;

  bool hasRequest(String command) =>
      requests.any((request) => request['command'] == command);

  Map<String, Object?> request(String command) =>
      requests.firstWhere((request) => request['command'] == command);

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    unawaited(_exit(-15));
    return true;
  }

  Future<void> terminateForDeviceLoss() async {
    _sendEvent('terminated');
    await _exit(1);
  }

  void sendReverseRequest(String command) {
    final seq = _seq++;
    lastReverseSeq = seq;
    _channel.send({
      'seq': seq,
      'type': 'request',
      'command': command,
      'arguments': {
        'kind': 'integrated',
        'title': 'Flutter',
        'cwd': Directory.current.path,
        'args': ['flutter'],
      },
    });
  }

  void _handleRequest(Map<String, Object?> request) {
    if (request['type'] == 'response') {
      responses.add(request);
      return;
    }
    requests.add(request);
    final requestSeq = request['seq'];
    final command = request['command'];
    if (requestSeq is! int || command is! String) {
      return;
    }
    _sendResponse(requestSeq, command);
    switch (command) {
      case 'initialize':
        _sendEvent('initialized');
      case 'launch':
      case 'attach':
        _sendEvent('flutter.appStarted');
      case 'disconnect':
      case 'terminate':
        _sendEvent('terminated');
        unawaited(_exit(0));
    }
  }

  void _sendResponse(int requestSeq, String command) {
    _channel.send({
      'seq': _seq++,
      'type': 'response',
      'request_seq': requestSeq,
      'success': true,
      'command': command,
      if (command == 'setBreakpoints')
        'body': {
          'breakpoints': [
            {'verified': true, 'line': 1},
          ],
        },
    });
  }

  void _sendEvent(String event) {
    _channel.send({
      'seq': _seq++,
      'type': 'event',
      'event': event,
    });
  }

  Future<void> _exit(int code) async {
    if (_exitCode.isCompleted) {
      return;
    }
    _exitCode.complete(code);
    await _subscription.cancel();
    await _channel.close();
    await _stdout.close();
    await _stderr.close();
    unawaited(stdin.close());
  }
}

final class _ControllerConsumer implements StreamConsumer<List<int>> {
  _ControllerConsumer(this.controller);

  final StreamController<List<int>> controller;

  @override
  Future<void> addStream(Stream<List<int>> stream) =>
      controller.addStream(stream);

  @override
  Future<void> close() => controller.close();
}
