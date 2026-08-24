# Flutter Alive for VS Code and Cursor

This extension registers the `flutter_alive` debug type and launches the
long-lived `flutter_alive debug-adapter` bridge. The bridge wraps Flutter's
official `flutter debug-adapter`, suppresses transient termination during
physical-device loss, and replays debugger configuration after reconnect.

Install the `flutter_alive` Dart executable first, then use:

```json
{
  "type": "flutter_alive",
  "request": "launch",
  "name": "Flutter Alive",
  "program": "lib/main.dart",
  "deviceId": "R5CXA4MJTPX",
  "toolArgs": ["--flavor", "staging"],
  "args": [],
  "env": {}
}
```

Run **Flutter Alive: Migrate Dart Launch Configuration** to copy an existing
Dart launch entry to the new debug type.
