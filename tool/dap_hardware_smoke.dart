import 'dart:async';
import 'dart:io';

import 'package:async/async.dart';
import 'package:flutter_alive/src/dap/dap_protocol.dart';
import 'package:path/path.dart' as path;

Future<void> main(List<String> arguments) async {
  if (arguments.length < 2) {
    stderr.writeln(
      'Usage: dart run tool/dap_hardware_smoke.dart <project> <device-id> '
      '[--adb-reset]',
    );
    exitCode = 64;
    return;
  }
  final project = Directory(arguments[0]).absolute.path;
  final deviceId = arguments[1];
  final resetAdb = arguments.contains('--adb-reset');
  final executable = path.normalize(
    path.join(Directory.current.path, 'bin', 'flutter_alive.dart'),
  );
  final process = await Process.start(
    Platform.resolvedExecutable,
    [executable, 'debug-adapter', '--alive-attach-timeout=10'],
    workingDirectory: project,
  );
  final stderrSubscription = process.stderr.listen(stderr.add);
  final channel = DapProtocolChannel(
    input: process.stdout,
    writeBytes: process.stdin.add,
  );
  final messages = StreamQueue<Map<String, Object?>>(channel.messages);
  var seq = 1;

  channel.send({
    'seq': seq++,
    'type': 'request',
    'command': 'initialize',
    'arguments': {
      'adapterID': 'flutter_alive_smoke',
      'linesStartAt1': true,
      'columnsStartAt1': true,
      'pathFormat': 'path',
      'supportsRunInTerminalRequest': false,
    },
  });
  await _waitFor(messages, (message) => message['event'] == 'initialized');
  channel.send({
    'seq': seq++,
    'type': 'request',
    'command': 'setBreakpoints',
    'arguments': {
      'source': {'path': path.join(project, 'lib', 'main.dart')},
      'breakpoints': [
        {'line': 1},
      ],
    },
  });
  channel.send({
    'seq': seq++,
    'type': 'request',
    'command': 'configurationDone',
  });
  final launchSeq = seq++;
  channel.send({
    'seq': launchSeq,
    'type': 'request',
    'command': 'launch',
    'arguments': {
      'program': 'lib/main.dart',
      'cwd': project,
      'deviceId': deviceId,
      'toolArgs': <String>[],
      'args': <String>[],
      'env': <String, String>{},
    },
  });
  var launchSucceeded = false;
  var appStarted = false;
  await _waitFor(
    messages,
    (message) {
      launchSucceeded = launchSucceeded ||
          message['type'] == 'response' &&
              message['request_seq'] == launchSeq &&
              message['success'] == true;
      appStarted = appStarted || message['event'] == 'flutter.appStarted';
      return launchSucceeded && appStarted;
    },
    timeout: const Duration(minutes: 5),
  );
  stdout.writeln('DAP launch succeeded on $deviceId.');

  if (resetAdb) {
    final bridgePid = process.pid;
    await Process.run('adb', ['kill-server']);
    await Future<void>.delayed(const Duration(seconds: 10));
    await Process.run('adb', ['start-server']);
    final recovery = await _waitFor(
      messages,
      (message) {
        if (message['event'] == 'terminated' || message['event'] == 'exited') {
          throw StateError('Outer DAP session terminated during reconnect.');
        }
        if (message['event'] != 'output') {
          return false;
        }
        final body = message['body'];
        final output = body is Map<Object?, Object?>
            ? body['output']?.toString() ?? ''
            : '';
        return output.contains('Reattached') || output.contains('Relaunched');
      },
      timeout: const Duration(minutes: 5),
    );
    stdout.writeln(
      'DAP reconnect succeeded with unchanged bridge PID $bridgePid: $recovery',
    );
  }

  final disconnectSeq = seq++;
  channel.send({
    'seq': disconnectSeq,
    'type': 'request',
    'command': 'disconnect',
    'arguments': {'terminateDebuggee': true},
  });
  await process.exitCode.timeout(const Duration(seconds: 15));
  await messages.cancel(immediate: true);
  await channel.close();
  await stderrSubscription.cancel();
}

Future<Map<String, Object?>> _waitFor(
  StreamQueue<Map<String, Object?>> messages,
  bool Function(Map<String, Object?> message) predicate, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  return Future<Map<String, Object?>>(() async {
    while (await messages.hasNext) {
      final message = await messages.next;
      if (predicate(message)) {
        return message;
      }
    }
    throw StateError('DAP stream ended before the expected message.');
  }).timeout(timeout);
}
