# Architecture

## Purpose

Flutter Alive separates the lifetime of the developer-facing server from the
lifetime of a Flutter debug connection. A device or VM Service can disappear
without terminating the parent supervisor.

## Components

```text
┌──────────────────────────────────────────────────────────────┐
│ flutter_alive                                               │
│                                                              │
│  CLI/config ──▶ supervisor state machine ◀── project watcher │
│                    │                     ▲                    │
│                    ▼                     │                    │
│       flutter daemon JSON-RPC ── device events               │
│                    │                                          │
│                    ▼                                          │
│   flutter run/attach --machine ── app events and commands    │
└──────────────────────────────────────────────────────────────┘
```

- **CLI/config:** owns public arguments, YAML precedence, diagnostics, and
  human or JSON output.
- **Machine protocol:** frames Flutter's JSON arrays, correlates request IDs,
  and exposes typed events.
- **Daemon client:** keeps `flutter daemon` resident and monitors device events.
- **Runner session:** owns one `flutter run --machine` or
  `flutter attach --machine` child.
- **Device identity:** maps changing connection IDs back to one physical device.
- **Project watcher:** records whether disconnected changes are hot-reloadable
  or require a cold run.
- **Supervisor:** serializes lifecycle transitions and owns all cleanup.

## State Machine

```text
initializing
    │
    ▼
 waiting ───── device added ─────▶ launching ─────▶ running
    ▲                                      │           │
    │                                      │           ├── device removed
    │                                      │           ▼
    │                                      └──────▶ disconnected
    │                                                   │
    │                                             device added
    │                                                   ▼
    └──── error ◀── relaunching ◀── fallback ◀── reattaching

Any state ── q/Ctrl+C ──▶ stopping
```

All device, runner, file, terminal, and process-exit signals enter one queue.
This avoids overlapping attach/run attempts and stale child exit events.

## Initial Launch

1. Resolve Flutter from `--alive-flutter`, YAML, project FVM SDK, or `PATH`.
2. Validate Flutter 3.22+ and the current Flutter project.
3. Start `flutter daemon`, request protocol version, enable device polling.
4. Select one Android/iOS target and resolve its stable identity.
5. Start `flutter run --machine` with the current connection ID.
6. Wait for `app.started`, expose logs, and accept reload/restart requests.

## Reconnect Flow

1. Cache the target fingerprint before handling `device.removed`; ADB cannot
   query a phone after the connection is already gone.
2. Keep the parent process alive and terminate a stale local runner if needed.
3. Resolve the fingerprint of each new `device.added` event.
4. When the target reappears, debounce for 750 ms.
5. Skip attach if native or pubspec files changed.
6. Otherwise run `flutter attach --machine` with compatible original args.
7. If Dart/assets changed, issue hot reload and then hot restart if necessary.
8. Fall back to `flutter run --machine` on discovery, attach, or sync failure.

## Device Identity

| Platform | Stable identity | Fallback |
| --- | --- | --- |
| Android physical | `adb -s <id> shell getprop ro.serialno` | Flutter ID, then device name |
| iOS physical | Flutter/Xcode UDID | Flutter ID |
| Emulator/simulator | Flutter device ID | Device name |

The removed-device event uses the previously cached fingerprint. Querying ADB
after removal would incorrectly replace the stable serial with the obsolete USB
or Wi-Fi connection ID.

## Failure Policy

- Flutter daemon failures retry after 1, 2, and 4 seconds, then every 30 seconds.
- Unexpected runner crashes retry up to `max_runner_retries`.
- Rapid daemon/runner failures retain their retry count; the count resets only
  after the configured stability window or an explicit recovery action.
- Build/config failures remain in `error` until a project change or Enter.
- Attach failures are expected recovery failures and immediately fall back.
- Parent shutdown stops/detaches the runner, shuts down the daemon, restores
  terminal modes, closes watchers, and cancels subscriptions.

## Protocol Compatibility

Flutter 3.22 and current Flutter releases use daemon protocol `0.6.1`. Flutter
Alive warns when another version is detected but uses capability-compatible
requests instead of failing immediately.

Human output is never parsed when an official event exists. The only text
inspection is the compatibility fallback for recognizing Flutter's
"Lost connection to device" message.

## Security Decisions

- No shell invocation or string-interpolated commands.
- No telemetry or external service.
- Machine output can be emitted as JSON Lines for automation.
- Verbose command logging must redact likely secret argument values before a
  stable release.

## Extension Points

- A background daemon can wrap the existing supervisor without changing runner
  or device protocol code.
- Multiple devices require one supervisor state machine per target.
- The v1.1 DAP bridge wraps replaceable official Flutter debug adapters, reuses
  stable device identity, and preserves the editor-facing DAP session.
