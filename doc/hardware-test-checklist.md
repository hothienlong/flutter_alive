# Hardware Release Checklist

Complete this checklist before a stable release that changes reconnect logic.
Latest automated-transport evidence is recorded in
[validation-2026-08-24.md](validation-2026-08-24.md).

## Common Setup

- [ ] Record host OS, Dart version, Flutter version, and device OS.
- [ ] Run `flutter_alive doctor` successfully.
- [ ] Use a fixture app with a visible counter to verify runtime state.
- [ ] Capture `--alive-json --alive-verbose` output and remove sensitive data.

## Android USB Reconnect

- [ ] Start on a physical Android device over USB.
- [ ] Confirm hot reload and hot restart work.
- [ ] Increment the fixture counter, then unplug USB.
- [ ] Wait at least five minutes and confirm the Flutter Alive PID is unchanged.
- [ ] Reconnect USB and confirm attach is attempted automatically.
- [ ] Confirm the counter survives when attach succeeds.
- [ ] Kill the app, reconnect again, and confirm cold-run fallback.

## Android USB to Wi-Fi

- [ ] Configure wireless debugging before starting the test.
- [ ] Start with the USB Flutter device ID.
- [ ] Remove USB and connect through ADB Wi-Fi.
- [ ] Confirm the Wi-Fi ID maps to the original hardware serial.
- [ ] Confirm only the selected phone is used when two identical models exist.

## iOS

- [ ] Enable Connect via Network in Xcode.
- [ ] Start on a physical iOS device.
- [ ] Disconnect cable/network and confirm the parent remains alive.
- [ ] Restore the connection and verify attach-first recovery.
- [ ] Terminate the app and verify launch fallback.

## Failure and Cleanup

- [ ] Introduce a Dart compile error and verify no infinite build loop.
- [ ] Fix the file and verify the runner retries.
- [ ] Change `pubspec.yaml` while disconnected and verify attach is skipped.
- [ ] Press `d`, Enter, `q`, and Ctrl+C and verify documented behavior.
- [ ] Verify no Flutter daemon, runner, or port-forwarding process is orphaned.
