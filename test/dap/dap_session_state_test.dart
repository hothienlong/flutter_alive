import 'package:flutter_alive/src/dap/dap_session_state.dart';
import 'package:test/test.dart';

void main() {
  test('rebuilds launch and attach requests for a replacement device ID', () {
    final state = DapSessionState()
      ..record({
        'seq': 1,
        'type': 'request',
        'command': 'initialize',
        'arguments': {'adapterID': 'flutter_alive'},
      })
      ..record({
        'seq': 2,
        'type': 'request',
        'command': 'launch',
        'arguments': {
          'program': 'lib/main.dart',
          'deviceId': 'USB-DEVICE',
          'appId': 'com.example.app',
          'flutterMode': 'profile',
          'toolArgs': ['--flavor', 'staging', '-d', 'USB-DEVICE'],
        },
      });

    final launch = state.launchRequest(10, '192.168.1.9:5555');
    final launchArguments = launch['arguments'] as Map<String, Object?>;
    expect(launchArguments, isNot(contains('deviceId')));
    expect(launchArguments['toolArgs'], [
      '--flavor',
      'staging',
      '--profile',
      '-d',
      '192.168.1.9:5555',
    ]);

    final attach = state.attachRequest(11, '192.168.1.9:5555');
    final attachArguments = attach['arguments'] as Map<String, Object?>;
    expect(attach['command'], 'attach');
    expect(attachArguments, isNot(contains('program')));
    expect(
      attachArguments['toolArgs'],
      contains('--app-id=com.example.app'),
    );
  });

  test('keeps only the latest breakpoint configuration per source', () {
    final state = DapSessionState()
      ..record({
        'seq': 1,
        'type': 'request',
        'command': 'setBreakpoints',
        'arguments': {
          'source': {'path': '/project/lib/main.dart'},
          'breakpoints': [
            {'line': 10},
          ],
        },
      })
      ..record({
        'seq': 2,
        'type': 'request',
        'command': 'setBreakpoints',
        'arguments': {
          'source': {'path': '/project/lib/main.dart'},
          'breakpoints': [
            {'line': 20},
          ],
        },
      })
      ..record({
        'seq': 3,
        'type': 'request',
        'command': 'configurationDone',
      });
    var seq = 100;

    final replay = state.configurationRequests(() => seq++);

    expect(replay, hasLength(2));
    final breakpointArguments =
        replay.first['arguments'] as Map<String, Object?>;
    expect(breakpointArguments['breakpoints'], [
      {'line': 20},
    ]);
    expect(replay.last['command'], 'configurationDone');
  });
}
