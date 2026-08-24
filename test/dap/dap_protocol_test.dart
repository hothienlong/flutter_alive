import 'dart:async';

import 'package:flutter_alive/src/dap/dap_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('parses fragmented and consecutive DAP frames', () async {
    final input = StreamController<List<int>>();
    final encoded = <int>[];
    final encoder = DapProtocolChannel(
      input: const Stream<List<int>>.empty(),
      writeBytes: encoded.addAll,
    );
    encoder
      ..send({'seq': 1, 'type': 'request', 'command': 'initialize'})
      ..send({'seq': 2, 'type': 'request', 'command': 'launch'});
    final decoder = DapProtocolChannel(
      input: input.stream,
      writeBytes: (_) {},
    );
    final messages = decoder.messages.take(2).toList();

    input
      ..add(encoded.sublist(0, 7))
      ..add(encoded.sublist(7, 31))
      ..add(encoded.sublist(31));

    final decoded = await messages;
    expect(decoded.map((message) => message['command']), [
      'initialize',
      'launch',
    ]);
    await input.close();
    await encoder.close();
    await decoder.close();
  });

  test('reports malformed headers as protocol errors', () async {
    final input = StreamController<List<int>>();
    final channel = DapProtocolChannel(
      input: input.stream,
      writeBytes: (_) {},
    );

    final error = expectLater(channel.messages, emitsError(isFormatException));
    input.add('X-Test: true\r\n\r\n{}'.codeUnits);

    await error;
    await input.close();
    await channel.close();
  });
}
