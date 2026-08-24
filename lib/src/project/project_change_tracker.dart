import 'dart:async';

import 'package:path/path.dart' as path;
import 'package:watcher/watcher.dart';

enum ProjectChangeKind { hot, cold }

final class ProjectChangeTracker {
  ProjectChangeTracker(this.projectDirectory);

  final String projectDirectory;
  final StreamController<ProjectChangeKind> _changes =
      StreamController<ProjectChangeKind>.broadcast();
  StreamSubscription<WatchEvent>? _subscription;
  ProjectChangeKind? _dirtyKind;

  Stream<ProjectChangeKind> get changes => _changes.stream;
  ProjectChangeKind? get dirtyKind => _dirtyKind;

  Future<void> start() async {
    final watcher = DirectoryWatcher(projectDirectory);
    _subscription = watcher.events.listen((event) {
      final relative = path.relative(event.path, from: projectDirectory);
      if (_isIgnored(relative)) {
        return;
      }
      final kind = classify(relative);
      _dirtyKind = _merge(_dirtyKind, kind);
      if (!_changes.isClosed) {
        _changes.add(kind);
      }
    });
    await watcher.ready;
  }

  void markClean() {
    _dirtyKind = null;
  }

  Future<void> close() async {
    await _subscription?.cancel();
    await _changes.close();
  }

  static ProjectChangeKind classify(String relativePath) {
    final normalized = path.posix.normalize(relativePath.replaceAll('\\', '/'));
    if (normalized == 'pubspec.yaml' ||
        normalized == 'pubspec.lock' ||
        normalized.startsWith('android/') ||
        normalized.startsWith('ios/') ||
        normalized.startsWith('macos/') ||
        normalized.startsWith('linux/') ||
        normalized.startsWith('windows/')) {
      return ProjectChangeKind.cold;
    }
    return ProjectChangeKind.hot;
  }

  static bool _isIgnored(String relativePath) {
    final normalized = relativePath.replaceAll('\\', '/');
    return normalized == '.git' ||
        normalized.startsWith('.git/') ||
        normalized == '.dart_tool' ||
        normalized.startsWith('.dart_tool/') ||
        normalized == 'build' ||
        normalized.startsWith('build/') ||
        normalized == '.idea' ||
        normalized.startsWith('.idea/') ||
        normalized == '.vscode' ||
        normalized.startsWith('.vscode/');
  }

  static ProjectChangeKind _merge(
    ProjectChangeKind? current,
    ProjectChangeKind next,
  ) {
    if (current == ProjectChangeKind.cold || next == ProjectChangeKind.cold) {
      return ProjectChangeKind.cold;
    }
    return ProjectChangeKind.hot;
  }
}
