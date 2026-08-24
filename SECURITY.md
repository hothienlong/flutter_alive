# Security Policy

## Supported Versions

Security fixes are applied to the latest published minor release. During the
alpha period, only the newest prerelease is supported.

## Reporting a Vulnerability

Do not open a public issue for vulnerabilities involving command execution,
argument disclosure, local file access, or device identity leakage.

Use GitHub's private vulnerability reporting feature for this repository. If
private reporting is not available yet, contact the repository owner privately
before sharing reproduction details.

Reports should include the affected version, host OS, Flutter version, a
minimal reproduction, and whether sensitive command arguments appear in logs.

## Security Boundaries

- Flutter Alive executes only the configured Flutter binary, ADB identity
  lookup, and Xcode diagnostics.
- Configuration files are trusted local project input.
- No telemetry or network service is included.
- Child commands use structured argument lists and do not invoke a shell.
