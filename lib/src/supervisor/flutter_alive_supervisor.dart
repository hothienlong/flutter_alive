import 'dart:async';
import 'dart:io';

import 'package:async/async.dart';

import '../config/alive_config.dart';
import '../daemon/flutter_daemon_client.dart';
import '../device/device_identity_resolver.dart';
import '../device/device_info.dart';
import '../process/managed_process.dart';
import '../project/project_change_tracker.dart';
import '../runner/flutter_runner_session.dart';
import '../ui/alive_reporter.dart';
import '../ui/terminal_input.dart';
import 'retry_backoff.dart';
import 'supervisor_state.dart';

typedef DevicePicker = Future<DeviceInfo?> Function(List<DeviceInfo> devices);
typedef Delay = Future<void> Function(Duration duration);

final class FlutterAliveSupervisor {
  FlutterAliveSupervisor({
    required this.flutter,
    required this.workingDirectory,
    required this.config,
    required this.runArguments,
    required this.reporter,
    required this.devicePicker,
    this.attachEnabled = true,
    this.listenToProcessSignals = true,
    this.processStarter = startIoProcess,
    this.delay = Future<void>.delayed,
    DeviceIdentityResolver? identityResolver,
    ProjectChangeTracker? changeTracker,
    TerminalInput? terminalInput,
    Map<String, String>? environment,
  })  : identityResolver = identityResolver ?? const DeviceIdentityResolver(),
        changeTracker = changeTracker ?? ProjectChangeTracker(workingDirectory),
        terminalInput = terminalInput ?? TerminalInput(),
        environment = environment ?? Platform.environment;

  final ExecutableCommand flutter;
  final String workingDirectory;
  final AliveConfig config;
  final List<String> runArguments;
  final AliveReporter reporter;
  final DevicePicker devicePicker;
  final bool attachEnabled;
  final bool listenToProcessSignals;
  final ProcessStarter processStarter;
  final Delay delay;
  final DeviceIdentityResolver identityResolver;
  final ProjectChangeTracker changeTracker;
  final TerminalInput terminalInput;
  final Map<String, String> environment;

  final StreamController<_SupervisorSignal> _signals =
      StreamController<_SupervisorSignal>();
  final Map<String, TrackedDevice> _devices = {};
  final List<StreamSubscription<Object?>> _subscriptions = [];
  StreamQueue<_SupervisorSignal>? _queue;
  FlutterDaemonClient? _daemon;
  FlutterRunnerSession? _session;
  TrackedDevice? _target;
  SupervisorState _state = SupervisorState.initializing;
  bool _stopping = false;
  bool _paused = false;
  bool _hasLaunched = false;
  int _runnerFailures = 0;
  int _daemonGeneration = 0;
  int _sessionGeneration = 0;
  DateTime? _runnerStartedAt;
  final Completer<void> _stopRequested = Completer<void>();
  static const RetryBackoff _retryBackoff = RetryBackoff();

  SupervisorState get state => _state;

  void requestStop() {
    _emitSignal(const _StopRequested());
  }

  Future<int> run() async {
    reporter.serverStarted(pid: pid, project: workingDirectory);
    await changeTracker.start();
    await terminalInput.start();
    _queue = StreamQueue<_SupervisorSignal>(_signals.stream);
    _listenToInputs();
    if (listenToProcessSignals) {
      _listenToSignals();
    }
    _subscriptions.add(
      changeTracker.changes.listen((kind) {
        _emitSignal(_ProjectChanged(kind));
      }),
    );

    var daemonFailures = 0;
    try {
      while (!_stopping) {
        DateTime? daemonStartedAt;
        Object? daemonError;
        int? daemonExitCode;
        FlutterDaemonClient? daemon;
        try {
          _daemonGeneration += 1;
          final generation = _daemonGeneration;
          daemon = await FlutterDaemonClient.start(
            flutter: flutter,
            workingDirectory: workingDirectory,
            processStarter: processStarter,
            environment: environment,
            onLog: reporter.verbose ? reporter.log : null,
          );
          _daemon = daemon;
          daemonStartedAt = DateTime.now();
          daemonExitCode = await _runWithDaemon(daemon, generation);
        } on Object catch (error) {
          daemonError = error;
        } finally {
          await daemon?.shutdown();
          _daemon = null;
        }
        if (_stopping) {
          break;
        }
        if (daemonStartedAt != null &&
            DateTime.now().difference(daemonStartedAt) >=
                config.daemonStabilityWindow) {
          daemonFailures = 0;
        }
        daemonFailures += 1;
        final retryDelay = _retryBackoff.delayForAttempt(daemonFailures);
        final reason = daemonError != null
            ? daemonError.toString()
            : 'process exited with code $daemonExitCode';
        reporter.warning(
          'Flutter daemon unavailable: $reason. Retrying in ${retryDelay.inSeconds}s.',
        );
        _setState(SupervisorState.waiting, detail: 'Flutter daemon retry');
        await _waitForRetry(retryDelay);
      }
      return 0;
    } finally {
      await _shutdown();
    }
  }

  Future<int> _runWithDaemon(
    FlutterDaemonClient daemon,
    int generation,
  ) async {
    if (daemon.protocolVersion != '0.6.1') {
      reporter.warning(
        'Flutter daemon protocol ${daemon.protocolVersion} is untested; expected 0.6.1.',
      );
    }
    final daemonSubscription = daemon.deviceEvents.listen((event) {
      unawaited(_resolveDeviceEvent(event, generation));
    });
    unawaited(
      daemon.exitCode.then(
        (code) => _emitSignal(_DaemonExited(generation, code)),
      ),
    );

    final devices = await daemon.getDevices();
    for (final device in devices.where(_isAllowedDevice)) {
      final tracked = await _track(device);
      _devices[device.id] = tracked;
    }
    await _selectInitialTarget();
    final target = _target;
    if (target != null && !_paused) {
      await _launchRun(target, relaunch: _hasLaunched);
    } else {
      _setState(SupervisorState.waiting, detail: _waitingDetail());
    }

    final queue = _queue;
    if (queue == null) {
      await daemonSubscription.cancel();
      return 0;
    }
    var daemonExited = false;
    var daemonExitCode = 0;
    while (!_stopping && !daemonExited) {
      final signal = await queue.next;
      switch (signal) {
        case _DaemonExited():
          if (signal.generation == generation) {
            daemonExited = true;
            daemonExitCode = signal.exitCode;
            if (!_stopping) {
              reporter.warning(
                'Flutter daemon exited with code ${signal.exitCode}.',
              );
            }
          }
        case _DeviceAdded():
          if (signal.generation == generation) {
            await _handleDeviceAdded(signal.device);
          }
        case _DeviceRemoved():
          if (signal.generation == generation) {
            await _handleDeviceRemoved(signal.device);
          }
        case _SessionExited():
          await _handleSessionExited(signal);
        case _ForceSessionStop():
          await _handleForceSessionStop(signal);
        case _ProjectChanged():
          await _handleProjectChanged(signal.kind);
        case _ReconcileDevices():
          await _handleDeviceReconcile(signal.generation);
        case _KeyPressed():
          await _handleKey(signal.key);
        case _StopRequested():
          _stopping = true;
      }
    }
    await daemonSubscription.cancel();
    if (!_stopping) {
      await _session?.killLocal();
      _session = null;
      _devices.clear();
      _setState(SupervisorState.waiting, detail: 'Restarting Flutter daemon');
    }
    return daemonExitCode;
  }

  Future<void> _selectInitialTarget() async {
    final selector = config.device;
    final candidates = _devices.values
        .map((tracked) => tracked.info)
        .where(_isSupportedMobileDevice)
        .toList(growable: false);
    if (selector != null && selector.isNotEmpty) {
      final selected = _matchSelector(candidates, selector);
      if (selected != null) {
        _target = _devices[selected.id];
        reporter.device('selected', selected);
      }
      return;
    }
    if (candidates.length == 1) {
      _target = _devices[candidates.single.id];
      reporter.device('selected', candidates.single);
      return;
    }
    if (candidates.isNotEmpty) {
      final selected = await devicePicker(candidates);
      if (selected != null) {
        _target = _devices[selected.id];
        reporter.device('selected', selected);
      }
    }
  }

  Future<void> _handleDeviceAdded(TrackedDevice added) async {
    _devices[added.info.id] = added;
    reporter.device('added', added.info);
    final currentTarget = _target;
    if (currentTarget == null) {
      final selector = config.device;
      if ((selector == null && _isSupportedMobileDevice(added.info)) ||
          (selector != null &&
              _isSupportedMobileDevice(added.info) &&
              _matchesSelector(added.info, selector))) {
        _target = added;
        reporter.device('selected', added.info);
      } else {
        return;
      }
    } else if (!currentTarget.fingerprint.matches(added.fingerprint)) {
      return;
    } else {
      _target = added;
    }

    final activeBeforeReconnect = _session;
    if (activeBeforeReconnect != null &&
        _state == SupervisorState.running &&
        _devices.containsKey(activeBeforeReconnect.deviceId)) {
      return;
    }

    await delay(config.reconnectDebounce);
    if (_stopping) {
      return;
    }
    _paused = false;
    final active = _session;
    if (active != null) {
      await active.killLocal();
      _session = null;
    }
    _runnerFailures = 0;
    await _recover(added);
  }

  Future<void> _handleDeviceRemoved(TrackedDevice removed) async {
    _devices.remove(removed.info.id);
    reporter.device('removed', removed.info);
    final target = _target;
    if (target == null || !target.fingerprint.matches(removed.fingerprint)) {
      return;
    }
    final replacement = _connectedTarget();
    if (replacement != null && replacement.info.id != removed.info.id) {
      _setState(
        SupervisorState.disconnected,
        detail: 'Switching connection to ${replacement.info.name}',
      );
      final active = _session;
      if (active != null) {
        await active.killLocal();
        _session = null;
      }
      await delay(config.reconnectDebounce);
      _runnerFailures = 0;
      await _recover(replacement);
      return;
    }
    _setState(SupervisorState.disconnected,
        detail: 'Waiting for ${removed.info.name}');
    final active = _session;
    if (active != null) {
      final generation = _sessionGeneration;
      Timer(
        const Duration(seconds: 2),
        () => _emitSignal(_ForceSessionStop(generation)),
      );
    }
  }

  Future<void> _handleSessionExited(_SessionExited signal) async {
    if (signal.generation != _sessionGeneration || signal.session != _session) {
      return;
    }
    _session = null;
    reporter.runner('stopped', {
      'mode': signal.session.mode.name,
      'deviceId': signal.session.deviceId,
      'exitCode': signal.exitCode,
      'lostConnection': signal.session.lostConnection,
    });
    if (_stopping) {
      return;
    }
    if (_paused) {
      _setState(SupervisorState.waiting,
          detail: 'Detached; press Enter to reconnect');
      return;
    }
    if (signal.session.lostConnection ||
        !_devices.containsKey(signal.session.deviceId)) {
      _devices.remove(signal.session.deviceId);
      _setState(SupervisorState.disconnected, detail: 'Device connection lost');
      _scheduleDeviceReconcile(_daemonGeneration);
      return;
    }
    if (signal.exitCode != 0 && signal.session.stopError == null) {
      final runnerStartedAt = _runnerStartedAt;
      if (runnerStartedAt != null &&
          DateTime.now().difference(runnerStartedAt) >=
              config.runnerStabilityWindow) {
        _runnerFailures = 0;
      }
    }
    if (signal.exitCode != 0 &&
        signal.session.stopError == null &&
        _runnerFailures < config.maxRunnerRetries) {
      _runnerFailures += 1;
      final delay = _retryBackoff.delayForAttempt(_runnerFailures);
      reporter.warning(
        'Runner crashed; retrying in ${delay.inSeconds}s '
        '($_runnerFailures/${config.maxRunnerRetries}).',
      );
      await _waitForRetry(delay);
      final target = _connectedTarget();
      if (target != null && !_stopping) {
        await _launchRun(target, relaunch: true);
      }
      return;
    }
    _setState(
      SupervisorState.error,
      detail:
          'Runner exited with code ${signal.exitCode}; edit a file or press Enter to retry',
    );
  }

  Future<void> _handleForceSessionStop(_ForceSessionStop signal) async {
    if (signal.generation != _sessionGeneration) {
      return;
    }
    final active = _session;
    if (active == null || _devices.containsKey(active.deviceId)) {
      return;
    }
    await active.killLocal();
  }

  Future<void> _handleProjectChanged(ProjectChangeKind kind) async {
    if (_state != SupervisorState.error || _paused || _session != null) {
      return;
    }
    final target = _connectedTarget();
    if (target != null) {
      _runnerFailures = 0;
      await _launchRun(target, relaunch: true);
    }
  }

  Future<void> _handleDeviceReconcile(int generation) async {
    if (_stopping ||
        generation != _daemonGeneration ||
        _state != SupervisorState.disconnected ||
        _session != null) {
      return;
    }
    final daemon = _daemon;
    if (daemon == null) {
      return;
    }
    try {
      final devices = await daemon.getDevices();
      for (final device in devices.where(_isSupportedMobileDevice)) {
        final tracked = await _track(device);
        _devices[device.id] = tracked;
        final target = _target;
        if (target != null && target.fingerprint.matches(tracked.fingerprint)) {
          await _handleDeviceAdded(tracked);
          return;
        }
      }
    } on Object catch (error) {
      reporter.warning('Device reconciliation failed: $error');
    }
    _scheduleDeviceReconcile(generation);
  }

  Future<void> _handleKey(String key) async {
    switch (key) {
      case 'q':
      case '\u0003':
        _emitSignal(const _StopRequested());
      case 'r':
        final success = await _session?.reload() ?? false;
        if (!success) {
          reporter.warning('Hot reload is not available.');
        }
      case 'R':
        final success = await _session?.reload(fullRestart: true) ?? false;
        if (!success) {
          reporter.warning('Hot restart is not available.');
        }
      case 'd':
        _paused = true;
        await _session?.detach();
        _setState(SupervisorState.waiting,
            detail: 'Detached; press Enter to reconnect');
      case '\n':
      case '\r':
        _paused = false;
        final target = _connectedTarget();
        if (_session == null && target != null) {
          _runnerFailures = 0;
          await _recover(target);
        }
      case 's':
        reporter.log(
            'State: ${_state.name}; device: ${_target?.info.name ?? 'none'}');
      case 'c':
        reporter.clear();
      case 'h':
        reporter.log(
          'Keys: r reload, R restart, s status, d detach, Enter retry, c clear, h help, q quit',
        );
    }
  }

  Future<void> _recover(TrackedDevice target) async {
    if (_session != null || _paused || _stopping) {
      return;
    }
    final dirtyKind = changeTracker.dirtyKind;
    if (!_hasLaunched ||
        !attachEnabled ||
        dirtyKind == ProjectChangeKind.cold) {
      await _launchRun(target, relaunch: _hasLaunched);
      return;
    }
    await _tryAttachThenRun(target);
  }

  Future<void> _tryAttachThenRun(TrackedDevice target) async {
    _setState(SupervisorState.reattaching, detail: target.info.name);
    reporter.reconnect('started', {'deviceId': target.info.id});
    FlutterRunnerSession? attachSession;
    try {
      attachSession = await _startSession(RunnerMode.attach, target);
      await attachSession.waitUntilStarted(timeout: config.attachTimeout);
      var synchronized = true;
      if (changeTracker.dirtyKind == ProjectChangeKind.hot) {
        synchronized = await attachSession.reload();
        if (!synchronized) {
          synchronized = await attachSession.reload(fullRestart: true);
        }
      }
      if (!synchronized) {
        throw StateError('Could not synchronize changed sources after attach.');
      }
      _session = attachSession;
      _hasLaunched = true;
      _runnerFailures = 0;
      _runnerStartedAt = DateTime.now();
      changeTracker.markClean();
      _setState(SupervisorState.running,
          detail: 'Reattached to ${target.info.name}');
      reporter.reconnect('attached', {
        'deviceId': target.info.id,
        if (attachSession.debugUri != null) 'debugUri': attachSession.debugUri,
      });
      return;
    } on Object catch (error) {
      reporter.warning('Attach failed: $error');
      await attachSession?.killLocal();
      if (_session == attachSession) {
        _session = null;
      }
      reporter.reconnect('fallback', {'deviceId': target.info.id});
      await _launchRun(target, relaunch: true);
    }
  }

  Future<void> _launchRun(
    TrackedDevice target, {
    required bool relaunch,
  }) async {
    if (_session != null || _stopping) {
      return;
    }
    _setState(
      relaunch ? SupervisorState.relaunching : SupervisorState.launching,
      detail: target.info.name,
    );
    FlutterRunnerSession? session;
    try {
      session = await _startSession(RunnerMode.run, target);
      await session.waitUntilStarted();
      _session = session;
      _hasLaunched = true;
      _runnerStartedAt = DateTime.now();
      changeTracker.markClean();
      _setState(SupervisorState.running, detail: target.info.name);
    } on Object catch (error) {
      await session?.killLocal();
      if (_session == session) {
        _session = null;
      }
      _setState(
        SupervisorState.error,
        detail: '$error Edit a file or press Enter to retry.',
      );
    }
  }

  Future<FlutterRunnerSession> _startSession(
    RunnerMode mode,
    TrackedDevice target,
  ) async {
    _sessionGeneration += 1;
    final generation = _sessionGeneration;
    final session = await FlutterRunnerSession.start(
      mode: mode,
      flutter: flutter,
      deviceId: target.info.id,
      workingDirectory: workingDirectory,
      runArguments: runArguments,
      processStarter: processStarter,
      environment: environment,
      appId: config.appId,
      onLog: (line, {error = false}) {
        reporter.log(line, error: error);
      },
    );
    _session = session;
    reporter.runner('started', {
      'mode': mode.name,
      'deviceId': target.info.id,
      'pid': session.process.pid,
    });
    unawaited(
      session.exitCode.then(
        (code) => _emitSignal(_SessionExited(generation, session, code)),
      ),
    );
    return session;
  }

  Future<void> _resolveDeviceEvent(
    DaemonDeviceEvent event,
    int generation,
  ) async {
    if (event.type == DaemonDeviceEventType.added) {
      if (!_isSupportedMobileDevice(event.device)) {
        return;
      }
      final tracked = await _track(event.device);
      _emitSignal(_DeviceAdded(generation, tracked));
    } else {
      if (!_isSupportedMobileDevice(event.device)) {
        return;
      }
      final tracked = _devices[event.device.id] ?? await _track(event.device);
      _emitSignal(_DeviceRemoved(generation, tracked));
    }
  }

  Future<TrackedDevice> _track(DeviceInfo device) async {
    final fingerprint = await identityResolver.resolve(device);
    return TrackedDevice(info: device, fingerprint: fingerprint);
  }

  TrackedDevice? _connectedTarget() {
    final target = _target;
    if (target == null) {
      return null;
    }
    for (final device in _devices.values) {
      if (target.fingerprint.matches(device.fingerprint)) {
        _target = device;
        return device;
      }
    }
    return null;
  }

  bool _isAllowedDevice(DeviceInfo device) =>
      device.isAllowedBy(config.connection);

  bool _isSupportedMobileDevice(DeviceInfo device) =>
      _isAllowedDevice(device) && device.isSupportedPhysicalMobile;

  DeviceInfo? _matchSelector(List<DeviceInfo> devices, String selector) {
    final exact = devices.where((device) => device.id == selector).toList();
    if (exact.length == 1) {
      return exact.single;
    }
    final prefix =
        devices.where((device) => device.id.startsWith(selector)).toList();
    if (prefix.length == 1) {
      return prefix.single;
    }
    final normalized = selector.toLowerCase();
    final names = devices
        .where((device) => device.name.toLowerCase() == normalized)
        .toList();
    return names.length == 1 ? names.single : null;
  }

  bool _matchesSelector(DeviceInfo device, String selector) {
    final normalized = selector.toLowerCase();
    return device.id == selector ||
        device.id.startsWith(selector) ||
        device.name.toLowerCase() == normalized;
  }

  String _waitingDetail() {
    final selector = config.device;
    return selector == null
        ? 'Waiting for an Android or iOS device'
        : 'Waiting for $selector';
  }

  void _setState(SupervisorState state, {String? detail}) {
    _state = state;
    reporter.stateChanged(state, detail: detail);
  }

  void _listenToInputs() {
    _subscriptions.add(
      terminalInput.keys.listen((key) => _emitSignal(_KeyPressed(key))),
    );
  }

  void _listenToSignals() {
    if (!Platform.isWindows) {
      _subscriptions.add(
        ProcessSignal.sigterm.watch().listen(
              (_) => _emitSignal(const _StopRequested()),
            ),
      );
    }
    _subscriptions.add(
      ProcessSignal.sigint.watch().listen(
            (_) => _emitSignal(const _StopRequested()),
          ),
    );
  }

  void _emitSignal(_SupervisorSignal signal) {
    if (signal is _StopRequested && !_stopRequested.isCompleted) {
      _stopping = true;
      _stopRequested.complete();
    }
    if (_signals.isClosed || (_stopping && signal is! _StopRequested)) {
      return;
    }
    _signals.add(signal);
  }

  void _scheduleDeviceReconcile(int generation) {
    Timer(
      const Duration(seconds: 2),
      () => _emitSignal(_ReconcileDevices(generation)),
    );
  }

  Future<void> _waitForRetry(Duration duration) async {
    await Future.any<void>([
      delay(duration),
      _stopRequested.future,
    ]);
  }

  Future<void> _shutdown() async {
    if (!_stopping) {
      _stopping = true;
    }
    _setState(SupervisorState.stopping);
    final session = _session;
    _session = null;
    await session?.stop();
    final daemon = _daemon;
    _daemon = null;
    await daemon?.shutdown();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await terminalInput.close();
    await changeTracker.close();
    await _queue?.cancel(immediate: true);
    await _signals.close();
    reporter.serverStopped();
  }
}

sealed class _SupervisorSignal {
  const _SupervisorSignal();
}

final class _DaemonExited extends _SupervisorSignal {
  const _DaemonExited(this.generation, this.exitCode);

  final int generation;
  final int exitCode;
}

final class _DeviceAdded extends _SupervisorSignal {
  const _DeviceAdded(this.generation, this.device);

  final int generation;
  final TrackedDevice device;
}

final class _DeviceRemoved extends _SupervisorSignal {
  const _DeviceRemoved(this.generation, this.device);

  final int generation;
  final TrackedDevice device;
}

final class _SessionExited extends _SupervisorSignal {
  const _SessionExited(this.generation, this.session, this.exitCode);

  final int generation;
  final FlutterRunnerSession session;
  final int exitCode;
}

final class _ForceSessionStop extends _SupervisorSignal {
  const _ForceSessionStop(this.generation);

  final int generation;
}

final class _ProjectChanged extends _SupervisorSignal {
  const _ProjectChanged(this.kind);

  final ProjectChangeKind kind;
}

final class _ReconcileDevices extends _SupervisorSignal {
  const _ReconcileDevices(this.generation);

  final int generation;
}

final class _KeyPressed extends _SupervisorSignal {
  const _KeyPressed(this.key);

  final String key;
}

final class _StopRequested extends _SupervisorSignal {
  const _StopRequested();
}
