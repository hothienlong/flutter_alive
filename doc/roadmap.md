# Roadmap

## v0.1 Alpha — Core Supervisor

- **P0 Enabler:** Dart CLI and process abstraction
- **P0 Feature:** Flutter daemon protocol client
- **P0 Feature:** `flutter run --machine` session control
- **P0 Story:** Parent remains alive after Android device removal
- **P0 Test:** Fake daemon and runner lifecycle harness

Exit criteria: the parent process waits indefinitely and relaunches the selected
Android device without requiring the user to restart Flutter Alive.

## v0.5 Beta — Recovery

- **P0 Feature:** attach-first recovery and hot source synchronization
- **P0 Feature:** Android USB/Wi-Fi stable identity
- **P0 Feature:** iOS UDID reconnect support
- **P1 Feature:** YAML configuration and JSON event stream
- **P1 Enabler:** hardware test matrix and diagnostics

Exit criteria: Android and iOS hardware checklists pass on supported host OSes.

## v1.0 — Stable CLI

- **P0 Enabler:** macOS/Linux/Windows process hardening
- **P0 Test:** no orphan child process across every shutdown path
- **P1 Feature:** polished terminal status and troubleshooting guidance
- **P1 Enabler:** pub.dev trusted publishing and signed/checksummed binaries
- **P1 Quality:** raise line coverage from the alpha floor to at least 85%

Exit criteria: CI, security review, package dry run, coverage target, and manual
hardware validation all pass.

## v1.1 — IDE Integration

- **P1 Enabler:** persistent Debug Adapter Protocol bridge
- **P1 Feature:** VS Code/Cursor `flutter_alive` debug type
- **P1 Story:** preserve one editor session across VM Service replacement
- **P1 Story:** replay breakpoints and exception settings after reconnect
- **P1 Test:** breakpoint hit after cable disconnect/reconnect without pressing F5

See [dap-v1.1.md](dap-v1.1.md) for the design contract.

## Project Organization

GitHub issues use the hierarchy `Epic → Feature → Story/Enabler → Test` and the
labels `priority-p0..p3`, platform labels, and component labels. Recommended
project states are Backlog, Ready, In Progress, Review, Testing, and Done.
