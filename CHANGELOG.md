# Changelog

All notable changes follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project adheres to [Semantic Versioning](https://semver.org/).

## [0.2.0](https://github.com/heavygee/hapi-monitor/compare/hapi-monitor-v0.1.2...hapi-monitor-v0.2.0) (2026-06-08)


### Features

* **tui:** surface cursorSessionProtocol for legacy stream-json holdouts ([#28](https://github.com/heavygee/hapi-monitor/issues/28)) ([#29](https://github.com/heavygee/hapi-monitor/issues/29)) ([d406b3c](https://github.com/heavygee/hapi-monitor/commit/d406b3c0dd16482b1fd9876f1d78ca51e48a8295))


### Bug Fixes

* chart shows both series at overlap via alternating colors ([#14](https://github.com/heavygee/hapi-monitor/issues/14)) ([#16](https://github.com/heavygee/hapi-monitor/issues/16)) ([3a75649](https://github.com/heavygee/hapi-monitor/commit/3a756493011247eae5b6168582f9b7791a9ecda8))
* clamp emit() to viewport height + tighten INACTIVE budget ([#12](https://github.com/heavygee/hapi-monitor/issues/12)) ([#13](https://github.com/heavygee/hapi-monitor/issues/13)) ([3c25a54](https://github.com/heavygee/hapi-monitor/commit/3c25a548cd53901ad0a8d10a9ac5e4ef4dc25734))
* **classify:** address codex review feedback on [#26](https://github.com/heavygee/hapi-monitor/issues/26) ([#27](https://github.com/heavygee/hapi-monitor/issues/27)) ([fe33043](https://github.com/heavygee/hapi-monitor/commit/fe33043459e31f075dc4948713e2d5e9c784b3c9))
* **classify:** don't auto-flag remote-machine sessions as ZOMBIE ([#25](https://github.com/heavygee/hapi-monitor/issues/25)) ([#26](https://github.com/heavygee/hapi-monitor/issues/26)) ([04c52bb](https://github.com/heavygee/hapi-monitor/commit/04c52bbab1c7bdd1c561eace73fc0ab76aaeac5e))
* render hotkey hint at column 0, not indented under chart ([#7](https://github.com/heavygee/hapi-monitor/issues/7)) ([8c280d9](https://github.com/heavygee/hapi-monitor/commit/8c280d94ffe6342a7a93e070de0af39f584ea5af)), closes [#6](https://github.com/heavygee/hapi-monitor/issues/6)
* share lint:py extractor between CI and npm script ([#9](https://github.com/heavygee/hapi-monitor/issues/9)) ([#11](https://github.com/heavygee/hapi-monitor/issues/11)) ([26a0ae9](https://github.com/heavygee/hapi-monitor/commit/26a0ae9755725cc2280f5529e346f8bb2295115f))
* **tui:** stable first-seen queue for attention rows ([#23](https://github.com/heavygee/hapi-monitor/issues/23)) ([#24](https://github.com/heavygee/hapi-monitor/issues/24)) ([372fd43](https://github.com/heavygee/hapi-monitor/commit/372fd4384fa8ce67e948d499f807b40703ff7f03))
* window INACTIVE section so it never blows past viewport ([#8](https://github.com/heavygee/hapi-monitor/issues/8)) ([#10](https://github.com/heavygee/hapi-monitor/issues/10)) ([bc13c08](https://github.com/heavygee/hapi-monitor/commit/bc13c08439c4b51c5a77411b3c77c6c84cb702b0))


### Documentation

* Docs:  ([d406b3c](https://github.com/heavygee/hapi-monitor/commit/d406b3c0dd16482b1fd9876f1d78ca51e48a8295))
* add NPM_SETUP.md - operator wiring for first v* tag ([e167fca](https://github.com/heavygee/hapi-monitor/commit/e167fca8831a78511b4cfdb26ff67838780e5f9e))
* add README hero (logo + real TUI screenshot) ([d8bb219](https://github.com/heavygee/hapi-monitor/commit/d8bb219b194e446f688e72e577c2a4cb53e630ec))
* add social-preview.png; drop duplicate H1 from README ([1b64bf8](https://github.com/heavygee/hapi-monitor/commit/1b64bf816dda7b4fdba71cba6115aa327c7ac99e))
* anatomy.md walks the dense TUI line by line ([#15](https://github.com/heavygee/hapi-monitor/issues/15)) ([#17](https://github.com/heavygee/hapi-monitor/issues/17)) ([7ee6fdd](https://github.com/heavygee/hapi-monitor/commit/7ee6fdda5b74a76cd42f60e8c38f9f0990d91b35))


### Continuous Integration

* **deps:** Bump actions/checkout from 4 to 6 ([#1](https://github.com/heavygee/hapi-monitor/issues/1)) ([1390b23](https://github.com/heavygee/hapi-monitor/commit/1390b23edf680c093e6d40cf3c6ad5e4d957731f))
* **deps:** Bump actions/setup-node from 4 to 6 ([#2](https://github.com/heavygee/hapi-monitor/issues/2)) ([161176c](https://github.com/heavygee/hapi-monitor/commit/161176c696905f06fbbc2798b34036709dde3fb3))
* **deps:** Bump actions/setup-python from 5 to 6 ([#4](https://github.com/heavygee/hapi-monitor/issues/4)) ([2b8590d](https://github.com/heavygee/hapi-monitor/commit/2b8590d636ed4b3a14df76fbdbb1f143b9bbed2a))
* **deps:** Bump gitleaks/gitleaks-action from 2 to 3 ([#3](https://github.com/heavygee/hapi-monitor/issues/3)) ([39d21d0](https://github.com/heavygee/hapi-monitor/commit/39d21d081ed0fa05cdb8b6a1361c8b9f9654fbc1))
* **deps:** Bump softprops/action-gh-release from 2 to 3 ([#5](https://github.com/heavygee/hapi-monitor/issues/5)) ([70cc8a5](https://github.com/heavygee/hapi-monitor/commit/70cc8a51a49202753f41300cd11a2a27f5253cfb))
* fix python extraction, drop missing p/bash pack, quote label colors ([5272f46](https://github.com/heavygee/hapi-monitor/commit/5272f4642ca5b9be509d4a7c065623be1f058108))
* **release:** upgrade npm to latest + node 22 so OIDC actually works ([#19](https://github.com/heavygee/hapi-monitor/issues/19)) ([#21](https://github.com/heavygee/hapi-monitor/issues/21)) ([8051c27](https://github.com/heavygee/hapi-monitor/commit/8051c271d18f7152110b083506a82104d0be8eed))
* **security:** switch release.yml to npm Trusted Publishing, bump to 0.1.1 ([#19](https://github.com/heavygee/hapi-monitor/issues/19)) ([#20](https://github.com/heavygee/hapi-monitor/issues/20)) ([73b2b30](https://github.com/heavygee/hapi-monitor/commit/73b2b30a1a1a5505e025a0ebade85a1104b33e00))

## [Unreleased]

## [0.1.2] - 2026-06-08

### Added
- Cursor session protocol indicator (#28). HAPI is migrating Cursor
  sessions from stream-json to ACP; metadata now carries a
  `cursorSessionProtocol` field. The monitor surfaces it so operators
  can spot legacy holdouts during the rollout: ACP rows keep the
  uppercase ` CURSOR ` badge, legacy rows render as lowercase
  ` cursor ` in dim gray AND their NOTE column gets a
  `[legacy stream-json]` marker. Width stays at 8 chars so column
  alignment holds. New `cursor-acp-mix` snapshot fixture + 3 new
  regression assertions cover the visual contract.

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
