import 'dart:convert';
import 'dart:io';

import '../device/device_info.dart';
import '../supervisor/supervisor_state.dart';
import 'sensitive_value_redactor.dart';

final class AliveReporter {
  AliveReporter({
    required this.jsonMode,
    required this.verbose,
    IOSink? output,
    IOSink? errorOutput,
    SensitiveValueRedactor redactor = const SensitiveValueRedactor(),
  })  : output = output ?? stdout,
        errorOutput = errorOutput ?? stderr,
        _redactor = redactor;

  final bool jsonMode;
  final bool verbose;
  final IOSink output;
  final IOSink errorOutput;
  final SensitiveValueRedactor _redactor;

  void serverStarted({required int pid, required String project}) {
    event('server.started', {'pid': pid, 'project': project});
    if (!jsonMode) {
      output.writeln('Flutter Alive is watching $project');
    }
  }

  void stateChanged(SupervisorState state, {String? detail}) {
    event('state.changed',
        {'state': state.name, if (detail != null) 'detail': detail});
    if (!jsonMode) {
      output.writeln('[${state.name}]${detail == null ? '' : ' $detail'}');
    }
  }

  void device(String action, DeviceInfo device) {
    event('device.$action', device.toJson());
    if (!jsonMode && (action == 'selected' || verbose)) {
      output.writeln('Device $action: ${device.name} (${device.id})');
    }
  }

  void runner(String action, Map<String, Object?> data) {
    event('runner.$action', data);
  }

  void reconnect(String action, Map<String, Object?> data) {
    event('reconnect.$action', data);
  }

  void log(String message, {bool error = false}) {
    final safeMessage = _redactor.redact(message);
    event('log', {'message': safeMessage, 'error': error});
    if (!jsonMode) {
      (error ? errorOutput : output).writeln(safeMessage);
    }
  }

  void warning(String message) {
    final safeMessage = _redactor.redact(message);
    event('error', {'message': safeMessage, 'recoverable': true});
    if (!jsonMode) {
      errorOutput.writeln('Warning: $safeMessage');
    }
  }

  void failure(String message) {
    final safeMessage = _redactor.redact(message);
    event('error', {'message': safeMessage, 'recoverable': false});
    if (!jsonMode) {
      errorOutput.writeln('Error: $safeMessage');
    }
  }

  void serverStopped() {
    event('server.stopped');
    if (!jsonMode) {
      output.writeln('Flutter Alive stopped.');
    }
  }

  void event(String name, [Map<String, Object?> data = const {}]) {
    if (jsonMode) {
      output.writeln(jsonEncode({'event': name, 'data': data}));
    }
  }

  void clear() {
    if (!jsonMode && stdout.hasTerminal) {
      output.write('\x1B[2J\x1B[H');
    }
  }
}
