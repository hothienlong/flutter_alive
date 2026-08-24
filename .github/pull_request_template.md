## What changed

Describe the developer-visible behavior and why it is needed.

## Verification

- [ ] `dart format --output=none --set-exit-if-changed .`
- [ ] `dart analyze --fatal-infos`
- [ ] `dart test`
- [ ] Tests cover new lifecycle/protocol behavior
- [ ] Documentation and changelog are updated when needed
- [ ] Hardware checklist completed for reconnect changes

## Security and compatibility

- [ ] No secrets or full Dart define values are logged
- [ ] Commands use executable arguments without shell interpolation
- [ ] Flutter 3.22 compatibility is preserved or the change is documented
