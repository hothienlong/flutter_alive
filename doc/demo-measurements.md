# Demo Measurement Notes

The README demos are product demonstrations backed by physical-device runs.
They are not intended to be universal Flutter build benchmarks.

## Environment

- Date: 2026-08-24
- Flutter: 3.27.4
- Device: Samsung SM S721B, Android 16
- Device ID: `R5CXA4MJTPX`
- Disconnect trigger: real `adb kill-server` transport reset
- Fixture: a small Flutter demo application

## Normal Flutter Run

The baseline used `flutter run -d R5CXA4MJTPX --no-pub`. After the transport
reset, the process emitted `Lost connection to device.` and exited.

Two warm relaunch observations on the demo fixture were:

- 6.4 seconds from a manually restarted terminal session to VM Service-ready
  output.
- 15.758 seconds from process start to the machine-protocol `app.started`
  event in a follow-up run.

The variation is expected. Build cache state, Gradle/Xcode work, application
size, plugin count, native dependencies, installation time, and device state
all affect relaunch duration. Production applications may take much longer.

## Flutter Alive Run

The recovery demo used the same physical device and transport-reset method.
The parent supervisor remained alive, detected the returning device, attempted
attachment, fell back to relaunch after the configured timeout, returned to
`running`, and accepted a hot reload command.

The comparison claims zero additional recovery commands, not zero wall-clock
recovery time. Runtime-state preservation and recovery duration remain
best-effort and environment-dependent.
