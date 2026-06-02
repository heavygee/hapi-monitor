# Changelog

All notable changes follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Initial extraction from `server-setup/scripts/hapi/` into a standalone repo.
- npm packaging with `bin/hapi-monitor.js` Node wrapper around the bash entrypoint.
- `npx hapi-monitor` support.
- `NPM_SETUP.md` operator doc for first-tag npm environment wiring.
- `scripts/owasp-gate.sh` local Semgrep mirror of the CI `owasp-sast` job.
- README hero logo + real TUI screenshot (`docs/logo.png`, `docs/screenshot.png`).
