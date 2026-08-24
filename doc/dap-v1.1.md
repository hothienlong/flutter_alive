# DAP Bridge v1.1 Preview

## Problem

Dart Code can replace the `flutter` executable with `customTool`, but its debug
adapter disposes the active run daemon when `app.stop` or the VM Service
disconnect occurs. A CLI process remaining alive is therefore not enough to
preserve a VS Code/Cursor debug session.

## Implemented Design

`flutter_alive debug-adapter` exposes one stable Debug Adapter Protocol
session to the editor and manage replaceable child Flutter debug adapters.

```text
VS Code/Cursor
      │ stable DAP over stdio
      ▼
Flutter Alive DAP bridge
      │ replaceable child DAP/VM Service connection
      ▼
Flutter device session
```

The bridge retains and replays:

- `initialize`, `launch`, and `configurationDone`
- source/function/exception breakpoints
- exception pause settings
- source mappings and package configuration
- device, program, tool arguments, environment, and Flutter mode

Transient child `terminated` and `exited` events will be suppressed while the
core supervisor is reconnecting. After connecting to the new VM Service, the
bridge replays configuration before resuming isolates.

## Launch Configuration

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

A minimal VS Code/Cursor extension in `packages/flutter_alive_vscode` registers
the debug type, starts the Dart DAP binary, and offers a command that copies
compatible fields from an existing `type: dart` configuration.

## Recovery Sequence

1. Suppress transient child `terminated` and `exited` events.
2. Keep the editor-facing DAP stream and debug session open.
3. Wait for the same stable Android serial or iOS UDID.
4. Start a replacement official `flutter debug-adapter` child.
5. Replay initialize, breakpoints, exception settings, and configuration done.
6. Try an `attach` request with the new connection ID.
7. If attach fails or times out, replace the child and replay a `launch`.
8. Resume forwarding events through the original editor session.

## Current Validation

- Fragmented and consecutive DAP frames are covered by unit tests.
- Launch arguments are rewritten when a USB ID becomes a Wi-Fi ID.
- Integration tests verify transient termination suppression, attach-first
  recovery, breakpoint replay, and a stable outer connection.
- The extension compiles with strict TypeScript and packages as a VSIX.

The remaining release gate is an editor-driven physical-device E2E test that
hits a real breakpoint after cable disconnect/reconnect.

## Acceptance Criteria

- The outer VS Code debug session ID does not change after reconnect.
- Existing breakpoints are installed in the replacement VM Service.
- A breakpoint can be hit after USB disconnect/reconnect without pressing F5.
- Stop and restart actions remain distinguishable from transient disconnects.
- Debug console output marks the reconnect period without emitting a final
  terminated event.

The DAP bridge remains an experimental preview until the physical VS Code and
Cursor acceptance checklist passes.
