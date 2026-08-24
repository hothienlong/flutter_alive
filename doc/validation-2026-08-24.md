# Validation Record - 2026-08-24

## Environment

- Host: macOS on Apple Silicon
- Flutter: 3.27.4
- Flutter daemon protocol: 0.6.1
- Android: Samsung SM S721B, Android 16 / API 36
- Connection: physical USB device `R5CXA4MJTPX`
- Fixture: `modules/demo-integrate-flutter/lib/main.dart`

## CLI Supervisor Transport Test

- Started Flutter Alive with supervisor PID `49617`.
- Confirmed the fixture reached `running` on the physical Android device.
- Stopped the ADB server for 10 seconds to simulate transport loss.
- Observed `running -> disconnected -> reattaching` without parent exit.
- Attach timed out after the configured 10 seconds.
- Observed automatic `flutter run --machine` fallback.
- Confirmed the fixture returned to `running` with supervisor PID `49617`.
- Confirmed `q` stopped the runner and daemon cleanly.

## DAP Bridge Hardware Test

- Started a real `flutter_alive debug-adapter` bridge around Flutter's official
  `flutter debug-adapter`.
- Sent initialize, source breakpoint, configuration, and launch requests over
  DAP stdio.
- Confirmed launch and `flutter.appStarted` on the physical Android device.
- Reset ADB for 10 seconds while the DAP session was active.
- Confirmed the bridge PID remained `52650`.
- Confirmed no outer `terminated` or `exited` event was emitted.
- Confirmed a replacement child adapter reattached successfully and replayed
  breakpoint configuration.

## Security Observation

The fixture printed a token using the format `TOKEN nè: <value>`. The log
redactor was expanded and the repeated hardware run confirmed the value is
emitted only as `TOKEN nè:<redacted>` in JSON output.

## Remaining Manual Gates

- Physical cable removal for at least five minutes.
- Counter/runtime-state preservation after a successful attach.
- Android USB-to-Wi-Fi connection-ID change on the same session.
- Breakpoint hit after reconnect inside VS Code and Cursor.
- Physical iOS cable/network reconnect and fallback validation.
