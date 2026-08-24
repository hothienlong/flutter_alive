import 'dart:async';
import 'dart:convert';

import 'package:flutter_alive/src/protocol/machine_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('MachineProtocolParser', () {
    const parser = MachineProtocolParser();

    test('parses events and responses', () {
      final messages = parser.parseLine(
        '[{"event":"app.started","params":{"appId":"a"}},'
        '{"id":7,"result":{"code":0}}]',
      );

      expect(messages, hasLength(2));
      final event = messages.first as MachineEvent;
      expect(event.name, 'app.started');
      expect(event.parameters['appId'], 'a');
      final response = messages.last as MachineResponse;
      expect(response.id, 7);
      expect((response.result as Map<Object?, Object?>)['code'], 0);
    });

    test('ignores human-readable output', () {
      expect(parser.parseLine('Building Android application...'), isEmpty);
    });

    test('rejects malformed machine envelopes', () {
      expect(() => parser.parseLine('[{"event":]'), throwsFormatException);
    });
  });

  test('MachineConnection correlates requests and responses', () async {
    final stdout = StreamController<List<int>>();
    final stderr = StreamController<List<int>>();
    String? requestLine;
    final exitCode = Completer<int>();
    final connection = MachineConnection(
      stdout: stdout.stream,
      stderr: stderr.stream,
      writeLine: (line) => requestLine = line,
      exitCode: exitCode.future,
    );

    final request = connection.request('daemon.version');
    await Future<void>.delayed(Duration.zero);
    final decoded = jsonDecode(requestLine ?? '') as List<Object?>;
    final envelope = decoded.single as Map<Object?, Object?>;
    final id = envelope['id'] as int;
    stdout.add(utf8.encode('[{"id":$id,"result":"0.6.1"}]\n'));

    expect(await request, '0.6.1');
    exitCode.complete(0);
    await stdout.close();
    await stderr.close();
  });

  test('MachineConnection fails pending requests when the process exits',
      () async {
    final stdout = StreamController<List<int>>();
    final stderr = StreamController<List<int>>();
    final exitCode = Completer<int>();
    final connection = MachineConnection(
      stdout: stdout.stream,
      stderr: stderr.stream,
      writeLine: (_) {},
      exitCode: exitCode.future,
    );

    final request = connection.request('device.getDevices');
    exitCode.complete(9);

    await expectLater(request, throwsStateError);
    await stdout.close();
    await stderr.close();
  });
}
