# Changelog

All notable changes follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.1] - 2026-06-02

### Security
- Release workflow now uses npm Trusted Publishing (OIDC) instead of a
  long-lived `NPM_TOKEN`. No bearer credentials live on the account or
  in GitHub secrets for routine publishes (#19).
- `NPM_SETUP.md` rewritten - Trusted Publishing is the documented
  primary path; token instructions demoted to a breakglass appendix.

## [0.1.0] - 2026-06-02

### Added
- Initial extraction from `server-setup/scripts/hapi/` into a standalone repo.
- npm packaging with `bin/hapi-monitor.js` Node wrapper around the bash entrypoint.
- `npx hapi-monitor` support.
- `NPM_SETUP.md` operator doc for first-tag npm environment wiring.
- `scripts/owasp-gate.sh` local Semgrep mirror of the CI `owasp-sast` job.
- README hero logo + real TUI screenshot (`docs/logo.png`, `docs/screenshot.png`).
- `docs/anatomy.md` walks the dense TUI line by line so new operators
  can read every glyph, color, badge, and indicator without guesswork (#15).
- `scripts/lint-py.sh` shared extractor used by both `npm run lint:py`
  and CI `python-syntax` job (#9).

### Fixed
- INACTIVE section no longer overflows the viewport when toggled on
  with many idle sessions; bottom region paginates within a shared
  budget with cursor-follow on both IDLE and INACTIVE windows (#8).
- Header no longer bounces 2 lines on every refresh tick - `emit()`
  pads or clamps to exactly the viewport height so the terminal never
  scrolls (#12).
- Chart shows both `working` and `peak` series at overlap via
  alternating per-cell colors (nvtop trick) - previously the
  second-drawn series silently overwrote the first (#14).
- `npm run lint:py` works under dash (npm's `/bin/sh`); previously
  failed due to bash-only process substitution + wrong awk extractor (#9).
- Hotkey hint rendered at column 0 instead of wrapping under the
  chart column (#7).
