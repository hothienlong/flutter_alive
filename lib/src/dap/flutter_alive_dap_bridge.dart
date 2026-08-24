import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../device/device_identity_resolver.dart';
import '../process/managed_process.dart';
import '../supervisor/retry_backoff.dart';
import '../ui/sensitive_value_redactor.dart';
import 'dap_protocol.dart';
import 'dap_session_state.dart';
import 'persistent_device_monitor.dart';

final class FlutterAliveDapBridge {
  FlutterAliveDapBridge({
    required this.flutter,
    required this.workingDirectory,
    required this.input,
    required this.output,
    required this.errorOutput,
    required this.processStarter,
    required this.environment,
    required this.attachTimeout,
    this.attachEnabled = true,
    this.delay = Future<void>.delayed,
    DeviceIdentityResolver? identityResolver,
  }) : deviceMonitor = PersistentDeviceMonitor(
          flutter: flutter,
          workingDirectory: workingDirectory,
          processStarter: processStarter,
          environment: environment,
          delay: delay,
          identityResolver: identityResolver ?? const DeviceIdentityResolver(),
          onLog: (message) => errorOutput.writeln(message),
        );

  final ExecutableCommand flutter;
  final String workingDirectory;
  final Stream<List<int>> input;
  final IOSink output;
  final IOSink errorOutput;
  final ProcessStarter processStarter;
  final Map<String, String> environment;
  final Duration attachTimeout;
  final bool attachEnabled;
  final Future<void> Function(Duration duration) delay;
  final PersistentDeviceMonitor deviceMonitor;

  final DapSessionState _state = DapSessionState();
  final SensitiveValueRedactor _redactor = const SensitiveValueRedactor();
  final Completer<void> _done = Completer<void>();
  final Map<int, Completer<Map<String, Object?>>> _internalRequests = {};
  final Map<int, int> _childReverseRequests = {};
  final List<Map<String, Object?>> _pendingClientMessages = [];
  static const RetryBackoff _backoff = RetryBackoff();
  DapProtocolChannel? _editor;
  StreamSubscription<Map<String, Object?>>? _editorSubscription;
  _ChildAdapter? _child;
  Future<void>? _childStart;
  Completer<void>? _initializedEvent;
  Completer<void>? _attemptFailure;
  int _childGeneration = 0;
  int _outgoingSeq = 1;
  int _internalSeq = 1000000000;
  bool _recovering = false;
  bool _stopping = false;

  Future<int> run() async {
    deviceMonitor.start();
    final editor = DapProtocolChannel(
      input: input,
      writeBytes: output.add,
    );
    _editor = editor;
    _editorSubscription = editor.messages.listen(
      (message) => unawaited(_handleEditorMessage(message)),
      onError: (Object error, StackTrace stackTrace) {
        _log('Editor DAP protocol error: $error');
        _finish();
      },
      onDone: _finish,
    );
    await _done.future;
    await _shutdown();
    return 0;
  }

  Future<void> _handleEditorMessage(Map<String, Object?> message) async {
    if (_stopping) {
      return;
    }
    _state.record(message);
    if (message['type'] == 'response') {
      final requestSeq = message['request_seq'];
      if (requestSeq is int) {
        final childRequestSeq = _childReverseRequests.remove(requestSeq);
        if (childRequestSeq != null) {
          final translated = Map<String, Object?>.from(message)
            ..['request_seq'] = childRequestSeq;
          await _forwardToChild(translated);
          return;
        }
      }
    }
    final command = message['command'];
    if (message['type'] != 'request' || command is! String) {
      await _forwardToChild(message);
      return;
    }
    if (command == 'disconnect' || command == 'terminate') {
      _stopping = true;
      await _forwardToChild(message);
      return;
    }
    if (command == 'launch' || command == 'attach') {
      unawaited(_forwardInitialLaunch(message));
      return;
    }
    if (_recovering) {
      if (_isConfigurationCommand(command)) {
        _pendingClientMessages.add(message);
      } else {
        _sendFailureResponse(message, 'Flutter debugger is reconnecting.');
      }
      return;
    }
    await _forwardToChild(message);
  }

  Future<void> _forwardInitialLaunch(Map<String, Object?> request) async {
    final selector = _state.deviceSelector;
    if (selector == null || selector.isEmpty) {
      _sendFailureResponse(
        request,
        'Flutter Alive requires deviceId in the launch configuration.',
      );
      return;
    }
    try {
      _sendOutput('Waiting for physical device $selector...');
      final target = await deviceMonitor.waitForTarget(selector);
      final seq = request['seq'];
      if (seq is! int || _stopping) {
        return;
      }
      final transformed = _state.launchRequest(seq, target.info.id);
      await _forwardToChild(transformed);
    } on Object catch (error) {
      _sendFailureResponse(request, error.toString());
    }
  }

  Future<void> _forwardToChild(Map<String, Object?> message) async {
    final child = await _ensureChild();
    if (!_stopping || message['command'] == 'disconnect') {
      child.channel.send(message);
    }
  }

  Future<_ChildAdapter> _ensureChild() async {
    final existing = _child;
    if (existing != null) {
      return existing;
    }
    final pending = _childStart;
    if (pending != null) {
      await pending;
      final started = _child;
      if (started == null) {
        throw StateError('Flutter debug adapter did not start.');
      }
      return started;
    }
    final start = _spawnChild();
    _childStart = start;
    try {
      await start;
    } finally {
      _childStart = null;
    }
    final started = _child;
    if (started == null) {
      throw StateError('Flutter debug adapter did not start.');
    }
    return started;
  }

  Future<void> _spawnChild() async {
    _childGeneration += 1;
    final generation = _childGeneration;
    final process = await processStarter(
      flutter.executable,
      flutter.argumentsFor([
        'debug-adapter',
        '--suppress-analytics',
        '--no-version-check',
      ]),
      workingDirectory: workingDirectory,
      environment: environment,
    );
    final child = _ChildAdapter(
      process: process,
      onMessage: (message) => _handleChildMessage(message, generation),
      onError: (message) => _log(message),
      onExit: (code) => _handleChildExit(code, generation),
    );
    if (_stopping || generation != _childGeneration) {
      await child.close();
      return;
    }
    _child = child;
  }

  void _handleChildMessage(Map<String, Object?> message, int generation) {
    if (generation != _childGeneration) {
      return;
    }
    final type = message['type'];
    if (type == 'response') {
      final requestSeq = message['request_seq'];
      if (requestSeq is int) {
        final pending = _internalRequests.remove(requestSeq);
        if (pending != null && !pending.isCompleted) {
          pending.complete(message);
          return;
        }
      }
    }
    if (type == 'event') {
      final event = message['event'];
      if (_recovering && event == 'initialized') {
        final initialized = _initializedEvent;
        if (initialized != null && !initialized.isCompleted) {
          initialized.complete();
        }
        return;
      }
      if ((event == 'terminated' || event == 'exited') &&
          !_stopping &&
          _state.hasLaunchRequest) {
        final failure = _attemptFailure;
        if (_recovering && failure != null && !failure.isCompleted) {
          failure.completeError(StateError('Child adapter terminated.'));
        } else {
          _beginRecovery();
        }
        return;
      }
    }
    _sendToEditor(message);
  }

  void _handleChildExit(int exitCode, int generation) {
    if (generation != _childGeneration) {
      return;
    }
    _child = null;
    if (_stopping) {
      _finish();
      return;
    }
    final failure = _attemptFailure;
    if (_recovering && failure != null && !failure.isCompleted) {
      failure.completeError(
        StateError('Flutter debug adapter exited with code $exitCode.'),
      );
      return;
    }
    if (_state.hasLaunchRequest) {
      _beginRecovery();
    }
  }

  void _beginRecovery() {
    if (_recovering || _stopping) {
      return;
    }
    _recovering = true;
    _sendOutput('Device connection lost. Flutter Alive is still running.');
    unawaited(_recover());
  }

  Future<void> _recover() async {
    var attempt = 0;
    while (!_stopping) {
      attempt += 1;
      try {
        final selector = _state.deviceSelector;
        if (selector == null || selector.isEmpty) {
          throw StateError('No deviceId is available for reconnect.');
        }
        await _disposeChild();
        _sendOutput('Waiting for $selector to reconnect...');
        final target = await deviceMonitor.waitForTarget(selector);
        if (attachEnabled) {
          try {
            await _runRecoveryAttempt('attach', target.info.id);
            await _completeRecovery('Reattached to ${target.info.name}.');
            return;
          } on Object catch (error) {
            _log('Attach recovery failed: $error');
            await _disposeChild();
          }
        }
        await _runRecoveryAttempt('launch', target.info.id);
        await _completeRecovery('Relaunched on ${target.info.name}.');
        return;
      } on Object catch (error) {
        if (_stopping) {
          return;
        }
        final retryDelay = _backoff.delayForAttempt(attempt);
        _sendOutput(
          'Reconnect failed: $error Retrying in ${retryDelay.inSeconds}s.',
          category: 'stderr',
        );
        await delay(retryDelay);
      }
    }
  }

  Future<void> _runRecoveryAttempt(String command, String deviceId) async {
    _attemptFailure = Completer<void>();
    _initializedEvent = Completer<void>();
    await _ensureChild();
    final initialize = _state.initializeRequest(_nextInternalSeq());
    await _sendInternal(initialize, const Duration(seconds: 15));
    final initialized = _initializedEvent;
    if (initialized == null) {
      throw StateError('Flutter debug adapter was not initialized.');
    }
    await _withAttemptFailure(
      initialized.future.timeout(const Duration(seconds: 15)),
    );
    for (final request in _state.configurationRequests(_nextInternalSeq)) {
      await _sendInternal(request, const Duration(seconds: 15));
    }
    final request = command == 'attach'
        ? _state.attachRequest(_nextInternalSeq(), deviceId)
        : _state.launchRequest(_nextInternalSeq(), deviceId);
    final timeout =
        command == 'attach' ? attachTimeout : const Duration(minutes: 5);
    final response = await _sendInternal(request, timeout);
    if (response['success'] != true) {
      throw StateError(
        response['message']?.toString() ?? '$command request failed.',
      );
    }
  }

  Future<Map<String, Object?>> _sendInternal(
    Map<String, Object?> request,
    Duration timeout,
  ) async {
    final seq = request['seq'];
    if (seq is! int) {
      throw const FormatException('Internal DAP request is missing seq.');
    }
    final completer = Completer<Map<String, Object?>>();
    _internalRequests[seq] = completer;
    final child = await _ensureChild();
    child.channel.send(request);
    try {
      return await _withAttemptFailure(completer.future.timeout(timeout));
    } finally {
      _internalRequests.remove(seq);
    }
  }

  Future<T> _withAttemptFailure<T>(Future<T> operation) async {
    final failure = _attemptFailure;
    if (failure == null) {
      return operation;
    }
    return Future.any<T>([
      operation,
      failure.future.then<T>((_) => throw StateError('Recovery failed.')),
    ]);
  }

  Future<void> _completeRecovery(String message) async {
    _recovering = false;
    _attemptFailure = null;
    _initializedEvent = null;
    _sendOutput(message);
    final pending = List<Map<String, Object?>>.from(_pendingClientMessages);
    _pendingClientMessages.clear();
    for (final request in pending) {
      await _forwardToChild(request);
    }
  }

  Future<void> _disposeChild() async {
    _childGeneration += 1;
    final child = _child;
    _child = null;
    await child?.close();
    final error = StateError('Flutter debug adapter was replaced.');
    for (final request in _internalRequests.values) {
      if (!request.isCompleted) {
        request.completeError(error);
      }
    }
    _internalRequests.clear();
    _childReverseRequests.clear();
  }

  void _sendToEditor(Map<String, Object?> message) {
    final copy = Map<String, Object?>.from(message);
    final childSeq = message['seq'];
    final outgoingSeq = _nextOutgoingSeq();
    copy['seq'] = outgoingSeq;
    if (message['type'] == 'request' && childSeq is int) {
      _childReverseRequests[outgoingSeq] = childSeq;
    }
    _editor?.send(copy);
  }

  void _sendOutput(String message, {String category = 'console'}) {
    _editor?.send({
      'seq': _nextOutgoingSeq(),
      'type': 'event',
      'event': 'output',
      'body': {
        'category': category,
        'output': '[Flutter Alive] ${_redactor.redact(message)}\n',
      },
    });
  }

  void _sendFailureResponse(
    Map<String, Object?> request,
    String message,
  ) {
    _editor?.send({
      'seq': _nextOutgoingSeq(),
      'type': 'response',
      'request_seq': request['seq'],
      'success': false,
      'command': request['command'],
      'message': _redactor.redact(message),
    });
  }

  int _nextOutgoingSeq() => _outgoingSeq++;
  int _nextInternalSeq() => _internalSeq++;

  bool _isConfigurationCommand(String command) => const {
        'setBreakpoints',
        'setExceptionBreakpoints',
        'setFunctionBreakpoints',
        'setInstructionBreakpoints',
        'setDataBreakpoints',
        'configurationDone',
      }.contains(command);

  void _log(String message) {
    errorOutput.writeln('[flutter_alive:dap] ${_redactor.redact(message)}');
  }

  void _finish() {
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  Future<void> _shutdown() async {
    _stopping = true;
    await _disposeChild();
    await deviceMonitor.stop();
    await _editorSubscription?.cancel();
    await _editor?.close();
  }
}

final class _ChildAdapter {
  _ChildAdapter({
    required this.process,
    required void Function(Map<String, Object?> message) onMessage,
    required void Function(String message) onError,
    required void Function(int exitCode) onExit,
  }) {
    channel = DapProtocolChannel(
      input: process.stdout,
      writeBytes: process.stdin.add,
    );
    _messageSubscription = channel.messages.listen(
      onMessage,
      onError: (Object error, StackTrace stackTrace) {
        onError('Child DAP protocol error: $error');
      },
    );
    _stderrSubscription = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(onError);
    unawaited(process.exitCode.then(onExit));
  }

  final ManagedProcess process;
  late final DapProtocolChannel channel;
  late final StreamSubscription<Map<String, Object?>> _messageSubscription;
  late final StreamSubscription<String> _stderrSubscription;
  bool _closed = false;

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    process.kill();
    try {
      await process.exitCode.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
    }
    await _messageSubscription.cancel();
    await _stderrSubscription.cancel();
    await channel.close();
  }
}
