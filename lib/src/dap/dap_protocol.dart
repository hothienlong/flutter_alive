import 'dart:async';
import 'dart:convert';

final class DapProtocolChannel {
  DapProtocolChannel({
    required Stream<List<int>> input,
    required void Function(List<int> bytes) writeBytes,
  }) : _writeBytes = writeBytes {
    _subscription = input.listen(
      _handleBytes,
      onError: _messages.addError,
      onDone: _messages.close,
    );
  }

  final void Function(List<int> bytes) _writeBytes;
  final StreamController<Map<String, Object?>> _messages =
      StreamController<Map<String, Object?>>();
  final List<int> _buffer = [];
  late final StreamSubscription<List<int>> _subscription;
  bool _closed = false;

  Stream<Map<String, Object?>> get messages => _messages.stream;

  void send(Map<String, Object?> message) {
    if (_closed) {
      throw StateError('DAP channel is closed.');
    }
    final body = utf8.encode(jsonEncode(message));
    final header = ascii.encode('Content-Length: ${body.length}\r\n\r\n');
    _writeBytes([...header, ...body]);
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _subscription.cancel();
    if (!_messages.isClosed) {
      await _messages.close();
    }
  }

  void _handleBytes(List<int> bytes) {
    _buffer.addAll(bytes);
    while (true) {
      final headerEnd = _indexOfHeaderEnd(_buffer);
      if (headerEnd < 0) {
        return;
      }
      final header = ascii.decode(_buffer.sublist(0, headerEnd));
      int contentLength;
      try {
        contentLength = _contentLength(header);
      } on Object catch (error, stackTrace) {
        _buffer.clear();
        if (!_messages.isClosed) {
          _messages.addError(error, stackTrace);
        }
        return;
      }
      final bodyStart = headerEnd + 4;
      final bodyEnd = bodyStart + contentLength;
      if (_buffer.length < bodyEnd) {
        return;
      }
      final body = utf8.decode(_buffer.sublist(bodyStart, bodyEnd));
      _buffer.removeRange(0, bodyEnd);
      try {
        final decoded = jsonDecode(body);
        if (decoded is! Map<Object?, Object?>) {
          throw const FormatException('DAP payload must be a JSON object.');
        }
        if (!_messages.isClosed) {
          _messages.add(
            decoded.map((key, value) => MapEntry(key.toString(), value)),
          );
        }
      } on Object catch (error, stackTrace) {
        if (!_messages.isClosed) {
          _messages.addError(error, stackTrace);
        }
      }
    }
  }

  static int _indexOfHeaderEnd(List<int> bytes) {
    for (var index = 0; index <= bytes.length - 4; index += 1) {
      if (bytes[index] == 13 &&
          bytes[index + 1] == 10 &&
          bytes[index + 2] == 13 &&
          bytes[index + 3] == 10) {
        return index;
      }
    }
    return -1;
  }

  static int _contentLength(String header) {
    for (final line in header.split('\r\n')) {
      final separator = line.indexOf(':');
      if (separator < 0) {
        continue;
      }
      final name = line.substring(0, separator).trim().toLowerCase();
      if (name != 'content-length') {
        continue;
      }
      final value = int.tryParse(line.substring(separator + 1).trim());
      if (value == null || value < 0) {
        break;
      }
      return value;
    }
    throw const FormatException('DAP message is missing Content-Length.');
  }
}
