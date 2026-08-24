# Changelog

All notable changes to Flutter Alive will be documented in this file.

The project follows [Semantic Versioning](https://semver.org/).

## 0.1.0-dev.1

- Add persistent Flutter daemon device monitoring.
- Add machine-protocol run and attach sessions.
- Keep the supervisor alive across device disconnects.
- Match Android USB and wireless connections by hardware serial.
- Add attach-first recovery with cold-run fallback.
- Add daemon restart backoff, runner retry ceilings, and stability windows.
- Add hot/cold dirty tracking across reconnect and USB-to-Wi-Fi handoff.
- Add YAML configuration, diagnostics, JSON events, and interactive commands.
- Redact common credentials from human and JSON logs.
- Add an experimental persistent DAP bridge around Flutter's official adapter.
- Add a VS Code/Cursor debug extension with launch-config migration.
- Add deterministic recovery integration tests, release CI, and OSS metadata.
