import 'dart:async';

import '../daemon/flutter_daemon_client.dart';
import '../device/device_identity_resolver.dart';
import '../device/device_info.dart';
import '../process/managed_process.dart';
import '../supervisor/retry_backoff.dart';

final class PersistentDeviceMonitor {
  PersistentDeviceMonitor({
    required this.flutter,
    required this.workingDirectory,
    required this.processStarter,
    required this.environment,
    this.delay = Future<void>.delayed,
    this.identityResolver = const DeviceIdentityResolver(),
    this.onLog,
  });

  final ExecutableCommand flutter;
  final String workingDirectory;
  final ProcessStarter processStarter;
  final Map<String, String> environment;
  final Future<void> Function(Duration duration) delay;
  final DeviceIdentityResolver identityResolver;
  final void Function(String message)? onLog;

  final Map<String, TrackedDevice> _devices = {};
  final List<Completer<void>> _waiters = [];
  static const RetryBackoff _backoff = RetryBackoff();
  FlutterDaemonClient? _daemon;
  TrackedDevice? _target;
  Future<void>? _monitorTask;
  bool _stopping = false;
  int _generation = 0;

  void start() {
    _monitorTask ??= _monitor();
  }

  Future<TrackedDevice> waitForTarget(String selector) async {
    start();
    while (!_stopping) {
      final match = _findTarget(selector);
      if (match != null) {
        _target ??= match;
        return match;
      }
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
    }
    throw StateError('Device monitor stopped.');
  }

  Future<void> stop() async {
    if (_stopping) {
      return;
    }
    _stopping = true;
    _notifyWaiters(StateError('Device monitor stopped.'));
    await _daemon?.shutdown();
    await _monitorTask;
  }

  Future<void> _monitor() async {
    var failures = 0;
    while (!_stopping) {
      FlutterDaemonClient? daemon;
      StreamSubscription<DaemonDeviceEvent>? subscription;
      try {
        _generation += 1;
        final generation = _generation;
        daemon = await FlutterDaemonClient.start(
          flutter: flutter,
          workingDirectory: workingDirectory,
          processStarter: processStarter,
          environment: environment,
          onLog: onLog,
        );
        _daemon = daemon;
        final devices = await daemon.getDevices();
        for (final device in devices.where(_isSupported)) {
          final tracked = await _track(device);
          if (generation == _generation && !_stopping) {
            _devices[device.id] = tracked;
          }
        }
        _notifyWaiters();
        subscription = daemon.deviceEvents.listen((event) {
          unawaited(_handleDeviceEvent(event, generation));
        });
        final startedAt = DateTime.now();
        final exitCode = await daemon.exitCode;
        if (_stopping) {
          break;
        }
        if (DateTime.now().difference(startedAt) >=
            const Duration(seconds: 30)) {
          failures = 0;
        }
        failures += 1;
        onLog?.call('Flutter daemon exited with code $exitCode.');
      } on Object catch (error) {
        if (_stopping) {
          break;
        }
        failures += 1;
        onLog?.call('Flutter daemon unavailable: $error');
      } finally {
        await subscription?.cancel();
        await daemon?.shutdown();
        if (_daemon == daemon) {
          _daemon = null;
        }
        _devices.clear();
      }
      if (!_stopping) {
        await delay(_backoff.delayForAttempt(failures));
      }
    }
  }

  Future<void> _handleDeviceEvent(
    DaemonDeviceEvent event,
    int generation,
  ) async {
    if (_stopping || generation != _generation || !_isSupported(event.device)) {
      return;
    }
    if (event.type == DaemonDeviceEventType.removed) {
      _devices.remove(event.device.id);
      _notifyWaiters();
      return;
    }
    final tracked = await _track(event.device);
    if (_stopping || generation != _generation) {
      return;
    }
    _devices[event.device.id] = tracked;
    _notifyWaiters();
  }

  TrackedDevice? _findTarget(String selector) {
    final target = _target;
    if (target != null) {
      for (final device in _devices.values) {
        if (target.fingerprint.matches(device.fingerprint)) {
          _target = device;
          return device;
        }
      }
      return null;
    }
    final normalized = selector.toLowerCase();
    final exact = _devices.values.where(
      (device) =>
          device.info.id == selector ||
          device.info.name.toLowerCase() == normalized,
    );
    if (exact.length == 1) {
      return exact.single;
    }
    final prefix = _devices.values.where(
      (device) => device.info.id.startsWith(selector),
    );
    return prefix.length == 1 ? prefix.single : null;
  }

  Future<TrackedDevice> _track(DeviceInfo device) async {
    final fingerprint = await identityResolver.resolve(device);
    return TrackedDevice(info: device, fingerprint: fingerprint);
  }

  bool _isSupported(DeviceInfo device) => device.isSupportedPhysicalMobile;

  void _notifyWaiters([Object? error]) {
    final waiters = List<Completer<void>>.from(_waiters);
    _waiters.clear();
    for (final waiter in waiters) {
      if (waiter.isCompleted) {
        continue;
      }
      if (error == null) {
        waiter.complete();
      } else {
        waiter.completeError(error);
      }
    }
  }
}
