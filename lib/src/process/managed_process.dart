import 'dart:io';

abstract interface class ManagedProcess {
  int get pid;
  Stream<List<int>> get stdout;
  Stream<List<int>> get stderr;
  IOSink get stdin;
  Future<int> get exitCode;
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]);
}

final class IoManagedProcess implements ManagedProcess {
  IoManagedProcess(this._process);

  final Process _process;

  @override
  int get pid => _process.pid;

  @override
  Stream<List<int>> get stdout => _process.stdout;

  @override
  Stream<List<int>> get stderr => _process.stderr;

  @override
  IOSink get stdin => _process.stdin;

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) =>
      _process.kill(signal);
}

typedef ProcessStarter = Future<ManagedProcess> Function(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
  required Map<String, String> environment,
});

Future<ManagedProcess> startIoProcess(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
  required Map<String, String> environment,
}) async {
  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
  );
  return IoManagedProcess(process);
}

final class ExecutableCommand {
  const ExecutableCommand(this.executable, [this.prefixArguments = const []]);

  final String executable;
  final List<String> prefixArguments;

  List<String> argumentsFor(List<String> arguments) => [
        ...prefixArguments,
        ...arguments,
      ];
}
