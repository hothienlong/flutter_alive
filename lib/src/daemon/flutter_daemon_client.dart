import 'dart:async';

import '../device/device_info.dart';
import '../process/managed_process.dart';
import '../protocol/machine_protocol.dart';

enum DaemonDeviceEventType { added, removed }

final class DaemonDeviceEvent {
  const DaemonDeviceEvent(this.type, this.device);

  final DaemonDeviceEventType type;
  final DeviceInfo device;
}

final class FlutterDaemonClient {
  FlutterDaemonClient._({
    required this.process,
    required this.connection,
    required this.protocolVersion,
    required StreamSubscription<MachineEvent> eventSubscription,
  }) : _eventSubscription = eventSubscription;

  static Future<FlutterDaemonClient> start({
    required ExecutableCommand flutter,
    required String workingDirectory,
    required ProcessStarter processStarter,
    required Map<String, String> environment,
    void Function(String line)? onLog,
  }) async {
    final arguments = flutter.argumentsFor([
      'daemon',
      '--suppress-analytics',
      '--no-version-check',
    ]);
    final process = await processStarter(
      flutter.executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
    );
    final connection = MachineConnection(
      stdout: process.stdout,
      stderr: process.stderr,
      writeLine: (line) => process.stdin.writeln(line),
      exitCode: process.exitCode,
      onUnhandledLine: onLog,
    );
    final deviceEvents = StreamController<DaemonDeviceEvent>.broadcast();
    final eventSubscription = connection.events.listen((event) {
      switch (event.name) {
        case 'device.added':
          if (!deviceEvents.isClosed) {
            deviceEvents.add(
              DaemonDeviceEvent(
                DaemonDeviceEventType.added,
                DeviceInfo.fromMap(event.parameters),
              ),
            );
          }
        case 'device.removed':
          if (!deviceEvents.isClosed) {
            deviceEvents.add(
              DaemonDeviceEvent(
                DaemonDeviceEventType.removed,
                DeviceInfo.fromMap(event.parameters),
              ),
            );
          }
        case 'daemon.logMessage':
          final message = event.parameters['message'];
          if (message is String) {
            onLog?.call(message);
          }
      }
    });

    try {
      final versionResult = await connection.request(
        'daemon.version',
        const {},
        const Duration(seconds: 15),
      );
      final version = versionResult as String? ?? 'unknown';
      final client = FlutterDaemonClient._(
        process: process,
        connection: connection,
        protocolVersion: version,
        eventSubscription: eventSubscription,
      );
      client._deviceEvents = deviceEvents;
      await connection.request('device.enable');
      return client;
    } on Object {
      await eventSubscription.cancel();
      await deviceEvents.close();
      process.kill();
      rethrow;
    }
  }

  final ManagedProcess process;
  final MachineConnection connection;
  final String protocolVersion;
  final StreamSubscription<MachineEvent> _eventSubscription;
  late final StreamController<DaemonDeviceEvent> _deviceEvents;
  bool _shuttingDown = false;

  Stream<DaemonDeviceEvent> get deviceEvents => _deviceEvents.stream;
  Future<int> get exitCode => process.exitCode;

  Future<List<DeviceInfo>> getDevices() async {
    final result = await connection.request('device.getDevices');
    if (result is! List<Object?>) {
      return const [];
    }
    return result
        .whereType<Map<Object?, Object?>>()
        .map(
          (map) => DeviceInfo.fromMap(
            map.map((key, value) => MapEntry(key.toString(), value)),
          ),
        )
        .toList(growable: false);
  }

  Future<void> shutdown() async {
    if (_shuttingDown) {
      return;
    }
    _shuttingDown = true;
    try {
      await connection.request(
        'daemon.shutdown',
        const {},
        const Duration(seconds: 2),
      );
      await process.exitCode.timeout(const Duration(seconds: 3));
    } on Object {
      process.kill();
    } finally {
      await _eventSubscription.cancel();
      await connection.close();
      await _deviceEvents.close();
    }
  }
}
