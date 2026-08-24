import 'dart:async';
import 'dart:convert';

sealed class MachineMessage {
  const MachineMessage();
}

final class MachineEvent extends MachineMessage {
  const MachineEvent(this.name, this.parameters);

  final String name;
  final Map<String, Object?> parameters;
}

final class MachineResponse extends MachineMessage {
  const MachineResponse({required this.id, this.result, this.error});

  final int id;
  final Object? result;
  final Object? error;
}

final class MachineProtocolParser {
  const MachineProtocolParser();

  List<MachineMessage> parseLine(String line) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('[') || !trimmed.endsWith(']')) {
      return const [];
    }

    final decoded = jsonDecode(trimmed);
    if (decoded is! List<Object?>) {
      return const [];
    }

    final messages = <MachineMessage>[];
    for (final item in decoded) {
      if (item is! Map<Object?, Object?>) {
        continue;
      }
      final map = item.map(
        (key, value) => MapEntry(key.toString(), value),
      );
      final event = map['event'];
      if (event is String) {
        messages.add(MachineEvent(event, _stringKeyedMap(map['params'])));
        continue;
      }
      final id = map['id'];
      if (id is int) {
        messages.add(
          MachineResponse(id: id, result: map['result'], error: map['error']),
        );
      }
    }
    return messages;
  }

  static Map<String, Object?> _stringKeyedMap(Object? value) {
    if (value is! Map<Object?, Object?>) {
      return const {};
    }
    return value.map((key, item) => MapEntry(key.toString(), item));
  }
}

final class MachineRequestError implements Exception {
  const MachineRequestError(this.method, this.error);

  final String method;
  final Object? error;

  @override
  String toString() => 'Machine request "$method" failed: $error';
}

final class MachineConnection {
  MachineConnection({
    required Stream<List<int>> stdout,
    required Stream<List<int>> stderr,
    required void Function(String line) writeLine,
    required Future<int> exitCode,
    this.onUnhandledLine,
  })  : _writeLine = writeLine,
        _exitCode = exitCode {
    _stdoutSubscription = stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_handleLine, onError: _handleStreamError);
    _stderrSubscription = stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => onUnhandledLine?.call(line));
    unawaited(exitCode.then(_handleExit, onError: _handleStreamError));
  }

  final void Function(String line) _writeLine;
  final Future<int> _exitCode;
  final void Function(String line)? onUnhandledLine;
  final MachineProtocolParser _parser = const MachineProtocolParser();
  final StreamController<MachineEvent> _events =
      StreamController<MachineEvent>.broadcast();
  final Map<int, _PendingRequest> _pending = {};
  late final StreamSubscription<String> _stdoutSubscription;
  late final StreamSubscription<String> _stderrSubscription;
  int _nextRequestId = 1;
  bool _closed = false;

  Stream<MachineEvent> get events => _events.stream;
  Future<int> get exitCode => _exitCode;

  Future<Object?> request(
    String method, [
    Map<String, Object?> parameters = const {},
    Duration timeout = const Duration(seconds: 30),
  ]) async {
    if (_closed) {
      throw StateError('Machine connection is closed.');
    }
    final id = _nextRequestId++;
    final completer = Completer<Object?>();
    final timer = Timer(timeout, () {
      final pending = _pending.remove(id);
      pending?.completer.completeError(
        TimeoutException('Timed out waiting for "$method".', timeout),
      );
    });
    _pending[id] = _PendingRequest(method, completer, timer);
    _writeLine(
      jsonEncode([
        {'id': id, 'method': method, 'params': parameters},
      ]),
    );
    return completer.future;
  }

  void _handleLine(String line) {
    List<MachineMessage> messages;
    try {
      messages = _parser.parseLine(line);
    } on FormatException {
      onUnhandledLine?.call(line);
      return;
    }
    if (messages.isEmpty) {
      onUnhandledLine?.call(line);
      return;
    }
    for (final message in messages) {
      switch (message) {
        case MachineEvent():
          if (!_events.isClosed) {
            _events.add(message);
          }
        case MachineResponse():
          final pending = _pending.remove(message.id);
          if (pending == null) {
            continue;
          }
          pending.timer.cancel();
          if (message.error != null) {
            pending.completer.completeError(
              MachineRequestError(pending.method, message.error),
            );
          } else {
            pending.completer.complete(message.result);
          }
      }
    }
  }

  void _handleExit(int code) {
    _closed = true;
    final error = StateError('Machine process exited with code $code.');
    for (final pending in _pending.values) {
      pending.timer.cancel();
      pending.completer.completeError(error);
    }
    _pending.clear();
    unawaited(_events.close());
  }

  void _handleStreamError(Object error, [StackTrace? stackTrace]) {
    if (!_events.isClosed) {
      _events.addError(error, stackTrace);
    }
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _stdoutSubscription.cancel();
    await _stderrSubscription.cancel();
    for (final pending in _pending.values) {
      pending.timer.cancel();
      pending.completer.completeError(StateError('Machine connection closed.'));
    }
    _pending.clear();
    await _events.close();
  }
}

final class _PendingRequest {
  const _PendingRequest(this.method, this.completer, this.timer);

  final String method;
  final Completer<Object?> completer;
  final Timer timer;
}
