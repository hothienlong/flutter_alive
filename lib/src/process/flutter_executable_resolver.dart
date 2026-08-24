import 'dart:io';

import 'package:path/path.dart' as path;

import 'managed_process.dart';

final class FlutterExecutableResolver {
  const FlutterExecutableResolver();

  Future<ExecutableCommand> resolve({
    required String workingDirectory,
    String? configuredPath,
  }) async {
    if (configuredPath != null && configuredPath.isNotEmpty) {
      return ExecutableCommand(_normalizeConfiguredPath(configuredPath));
    }

    final fvmBinary = path.join(
      workingDirectory,
      '.fvm',
      'flutter_sdk',
      'bin',
      Platform.isWindows ? 'flutter.bat' : 'flutter',
    );
    if (await File(fvmBinary).exists()) {
      return ExecutableCommand(fvmBinary);
    }
    return const ExecutableCommand('flutter');
  }

  String _normalizeConfiguredPath(String configuredPath) {
    final type = FileSystemEntity.typeSync(configuredPath);
    if (type == FileSystemEntityType.directory) {
      return path.join(
        configuredPath,
        'bin',
        Platform.isWindows ? 'flutter.bat' : 'flutter',
      );
    }
    return configuredPath;
  }
}
