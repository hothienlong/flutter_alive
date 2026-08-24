import 'dart:async';
import 'dart:convert';
import 'dart:io';

final class TerminalInput {
  TerminalInput({Stdin? input}) : _input = input ?? stdin;

  final Stdin _input;
  final StreamController<String> _keys = StreamController<String>.broadcast();
  StreamSubscription<String>? _subscription;
  bool? _previousEchoMode;
  bool? _previousLineMode;

  Stream<String> get keys => _keys.stream;

  Future<void> start() async {
    if (!_input.hasTerminal) {
      return;
    }
    try {
      _previousEchoMode = _input.echoMode;
      _previousLineMode = _input.lineMode;
      _input.echoMode = false;
      _input.lineMode = false;
    } on StdinException {
      return;
    }
    _subscription = _input.transform(utf8.decoder).listen((chunk) {
      for (final rune in chunk.runes) {
        _keys.add(String.fromCharCode(rune));
      }
    });
  }

  Future<void> close() async {
    await _subscription?.cancel();
    if (_input.hasTerminal) {
      final echoMode = _previousEchoMode;
      final lineMode = _previousLineMode;
      try {
        if (echoMode != null) {
          _input.echoMode = echoMode;
        }
        if (lineMode != null) {
          _input.lineMode = lineMode;
        }
      } on StdinException {
        // The terminal can disappear while the process is shutting down.
      }
    }
    await _keys.close();
  }
}
