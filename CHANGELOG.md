# Changelog

All notable changes follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed
- Local machineId is now read from `~/.hapi/settings.json` (canonical)
  with optional `HAPI_LOCAL_MACHINE_ID` env-var override; the vote
  fallback now cross-checks the session's `agentSessionId[:8]` against
  the local PID's cmdline to defeat PID-space collisions, and runs
  against the full unfiltered session list so an active `--filter`
  can't blind detection. Addresses three P2 codex-review findings on
  the original #25 fix (#26).
- Sessions running on a machine other than where `hapi-monitor` itself
  runs (Windows install, second Linux box, anything multi-machine) are
  no longer auto-flagged ZOMBIE the instant they go active. `classify()`
  now takes an `is_local` parameter and skips the local PID-aliveness
  check for remote sessions, trusting the hub's `active` flag (#25).
  Also corrects stale anatomy-doc description of the attention sort
  (still said "longest thinkingAt first" after #23 made it queue-order).
- ATTENTION REQUIRED rows no longer reshuffle when agents transition
  between think cycles. Previously sorted by `thinkingAt`, which jumped
  every time an agent finished one thought and started another, making
  multi-line marquee notes basically unreadable on busy hubs. Now uses
  a stable first-seen queue: new attention rows append at the bottom,
  status transitions (WORKING→STUCK?, etc.) keep the row in place
  (only the badge changes), and rows leaving attention close the gap.
  Idle/inactive sort (alpha by project) unchanged (#23).

### Added
- Golden-frame TUI snapshot tests (`test/render-snapshot.sh`,
  `test/fixtures/*.json`, `test/snapshots/*.txt`) covering five
  scenarios: minimal, alerts, idle-only, inactive-toggle, chart-overlap.
  CI fails on output drift; `bash test/update-snapshots.sh` regenerates
  intentionally (#18).
- `HAPI_RENDER_FIXTURE` env var: load a JSON fixture, freeze time, stub
  hub I/O, emit one deterministic frame. Renders without a hub and
  without the keyboard loop - the foundation that snapshot tests sit on.
- Explicit historic-bug regression assertions in the snapshot runner -
  if any of #7, #8, #12, or #14 silently regresses the relevant
  assertion blows up even if surrounding snapshot text drifted in a
  misleading way.
- `render-snapshot` CI job promoted to a required gate alongside
  `smoke`, `shellcheck`, and the security scanners.

## [0.1.1] - 2026-06-02

### Security
- Release workflow now uses npm Trusted Publishing (OIDC) instead of a
  long-lived `NPM_TOKEN`. No bearer credentials live on the account or
  in GitHub secrets for routine publishes (#19).
- Bump runner Node to 22 and force `npm install -g npm@latest` in
  `release.yml` - npm CLI 11.5.1+ is required for tokenless OIDC
  publishes; npm 10.x signs provenance but still demands a bearer
  token for the PUT and 404s without one.
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
