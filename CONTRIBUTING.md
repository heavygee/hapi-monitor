# Contributing to hapi-monitor

Welcome! Bugfixes, feature ideas, doc improvements — all genuinely
appreciated. This is a small focused tool and the contribution overhead
should match that.

## Issue-first workflow

**No ticket, no workee.** Bugs and feature requests both need a GitHub
Issue *before* implementation work starts, so we can agree on scope and
avoid duplicate effort. Exceptions: one-line typo / doc fixes, or fixes
you've already coordinated with a maintainer.

1. Search [existing issues](https://github.com/heavygee/hapi-monitor/issues)
   to avoid duplicates.
2. Open a new issue using the bug-report or feature-request template.
3. Wait for `accepted` / `help wanted` / a maintainer reply before
   investing significant time.

## Local setup

```bash
git clone https://github.com/heavygee/hapi-monitor.git
cd hapi-monitor

# Run directly from source:
bash src/hapi-monitor.sh --help

# Optional: install npm wrapper locally
npm link

# Optional: build the native chart plotter
npm run build:plotter
```

You need **Python 3.8+** and **bash 4+** on the test machine; for the npm
wrapper, **Node 14+** as well. A running HAPI hub is required to exercise
anything beyond `--help`.

## Pull request checklist

- [ ] Linked to an open issue (`Fixes #N`) unless it's a trivial doc fix
- [ ] Conventional commit title (see below)
- [ ] `shellcheck src/hapi-monitor.sh scripts/build-plotter.sh` clean
- [ ] Native plotter still compiles (`npm run build:plotter`)
- [ ] Smoke test: `npx hapi-monitor --help` shows the new flags / behaviour
- [ ] README + `--help` updated when user-facing behaviour changes

CI runs the same checks (lint + smoke + gitleaks + semgrep). PRs can't
merge to `main` until the aggregate `ci` job is green.

To run the Semgrep OWASP gate locally before pushing (recommended for
larger changes):

```bash
bash scripts/owasp-gate.sh   # uses Docker pinned image if available, falls back to local semgrep
```

## Conventional commits

PR titles and merge commits follow [Conventional Commits](https://www.conventionalcommits.org/):

```
feat: add 'h' hotkey to toggle help overlay
fix: graceful exit when /dev/tty unavailable
docs: clarify HAPI_SETTINGS env var
chore: bump dependencies
ci: add macOS smoke job
refactor: extract chart rendering into separate function
test: add fixture for STUCK? classification
```

Breaking changes get a `!` suffix or a `BREAKING CHANGE:` footer. Release
notes are generated from these.

## Style notes

- **Bash:** stick with `set -euo pipefail`, quote everything, no `eval`,
  prefer `[[ ]]` over `[ ]`. Shellcheck is the source of truth.
- **Embedded Python:** 3.8-compatible stdlib only. No `pip install`
  dependencies — this script ships as a single file so portability beats
  ergonomics. Catch network errors via `HubUnavailable`; never let
  `urllib.error.URLError` reach the top of the watch loop.
- **C plotter:** keep the binary tiny, no external deps beyond libc.
  Compatible with `gcc` and `clang`.
- **TUI:** any new rendering should respect `T.use` (color toggle), the
  configured terminal width `W`, and the flicker-free `emit()` path
  (no `\033[2J`).

## Cutting a release

**Releases are automated** via [release-please](https://github.com/googleapis/release-please).
You don't run `npm version` or `git tag` by hand.

How it works:

1. Land changes on `main` using [conventional commits](https://www.conventionalcommits.org/)
   (PR titles, since we squash-merge: `fix: ...`, `feat: ...`, `feat!: ...` for breaking).
2. release-please opens (or updates) a draft `chore(main): release X.Y.Z` PR with the
   bumped `package.json` and an auto-generated `CHANGELOG.md` entry.
3. Merge that release PR when you're ready to ship.
4. release-please tags `vX.Y.Z` and creates the GitHub Release.
5. The existing tag-triggered `release.yml` (OIDC trusted publishing) takes it
   from there - publishes to npm and attaches the bundle to the GitHub Release.

See [`NPM_SETUP.md`](NPM_SETUP.md) for the npm Trusted Publishing wiring (one-time setup).

If you ever need to release manually (release-please is broken, urgent hotfix, etc.):
bump `package.json`, append a dated `CHANGELOG.md` entry, push `vX.Y.Z` and the
tag-triggered workflow still works.

## Reporting security issues

Please **don't** open public issues for security problems. See
[SECURITY.md](SECURITY.md) for the private reporting channel.

## Where to find help

- Real-time: open an [issue](https://github.com/heavygee/hapi-monitor/issues)
  with the `question` label
- Async: see [SUPPORT.md](SUPPORT.md)

## Code of conduct

By participating you agree to our [Code of Conduct](CODE_OF_CONDUCT.md).
