import 'package:flutter_alive/src/project/project_change_tracker.dart';
import 'package:test/test.dart';

void main() {
  test('classifies source changes as hot', () {
    expect(
      ProjectChangeTracker.classify('lib/src/app.dart'),
      ProjectChangeKind.hot,
    );
  });

  test('classifies native and pubspec changes as cold', () {
    expect(
      ProjectChangeTracker.classify('android/app/build.gradle'),
      ProjectChangeKind.cold,
    );
    expect(
      ProjectChangeTracker.classify('pubspec.yaml'),
      ProjectChangeKind.cold,
    );
  });
}
