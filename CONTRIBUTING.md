# Contributing to Flutter Alive

Thank you for helping improve Flutter development workflows.

## Before Opening a Change

1. Search existing issues and discussions.
2. For protocol or lifecycle changes, describe the Flutter version, host OS,
   device platform, and connection type.
3. Keep v1 changes focused on the CLI supervisor. DAP and editor integration
   belong to the v1.1 design unless an issue explicitly expands the scope.

## Local Setup

```bash
dart pub get
dart analyze
dart test
```

Activate a local build for manual testing:

```bash
dart pub global activate --source path .
flutter_alive doctor
```

## Code Expectations

- Use pure Dart; do not add a Flutter SDK dependency to the package.
- Prefer official machine events over parsing human Flutter logs.
- Start processes with argument lists, not interpolated shell commands.
- Keep reconnect behavior covered by deterministic fake-process tests.
- Do not log full `--dart-define` values or other likely secrets.
- Run `dart format`, `dart analyze`, and `dart test` before submitting.

## Pull Requests

- Use a focused branch such as `feature/reconnect-backoff`.
- Follow Conventional Commits for PR titles.
- Add or update tests for behavior changes.
- Update documentation and the changelog when public behavior changes.
- Complete the hardware checklist when changing reconnect logic.

## Reporting Device-Specific Bugs

Include sanitized output from:

```bash
flutter_alive doctor
flutter_alive devices --alive-json
flutter_alive -d <device> --alive-json --alive-verbose
```

Remove application identifiers, local paths, IP addresses, and Dart define
values when they are sensitive.
