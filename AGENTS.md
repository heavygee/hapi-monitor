# AGENTS.md

Guidance for AI coding assistants working on this repo.

## Issue-first workflow (mandatory)

**No ticket, no workee.** Bugs and feature work require a tracked
GitHub Issue *before* you start writing code.

1. Check [open issues](https://github.com/heavygee/hapi-monitor/issues) for
   an existing match. If one exists and is unassigned, claim it via a
   comment before starting work.
2. If no issue exists, open one using the appropriate template and wait
   for triage / `accepted` / `help wanted` before investing significant
   time.
3. Branch from `main` with the issue number in the name:
   `fix/123-short-slug` / `feat/124-short-slug`.
4. Reference the issue in your PR description with `Fixes #N`.

**Exceptions:**

- one-line typo / doc fix
- declared hotfix mode by a maintainer
- security fix coordinated via private SECURITY.md channels (no public
  issue until disclosure)

## Repository shape

```
bin/hapi-monitor.js        Node CLI wrapper that exec's the bash entrypoint
src/hapi-monitor.sh        Main bash + embedded Python script (the real tool)
src/plotter/               Native C plotter source + binary (gitignored binary)
scripts/build-plotter.sh   Manual plotter build helper
test/smoke.sh              Lightweight smoke test (run in CI)
.github/                   CI, issue templates, dependabot
docs/                      Long-form supplementary docs (if any)
```

## What you can change without asking

- Bug fixes inside `src/hapi-monitor.sh` that are covered by an issue.
- New tests in `test/`.
- Doc edits (`README.md`, `CONTRIBUTING.md`, `docs/`).
- CI tuning that doesn't loosen security gates.

## What needs operator approval

- Renaming / removing existing CLI flags or env vars (back-compat breaks).
- Adding runtime dependencies (currently zero pip / npm deps in the runtime
  bash entrypoint — that's a feature).
- Touching `.github/workflows/release.yml` (it has npm publish credentials).
- Switching the licence.
- Major architectural changes (e.g. rewriting in Rust / Go / TypeScript).

## Local verification before opening a PR

```bash
shellcheck src/hapi-monitor.sh scripts/build-plotter.sh
bash scripts/build-plotter.sh           # native plotter still compiles
node bin/hapi-monitor.js --help         # wrapper still works
bash test/smoke.sh                       # smoke test passes (needs hub OR mocked)
```

CI runs the same checks. PRs can't merge until the aggregate `ci` job is
green.

## Conventional commits

PR titles use [Conventional Commits](https://www.conventionalcommits.org/).
See CONTRIBUTING.md for examples. Release notes are generated from these.

## Style anchors

- **Bash:** `set -euo pipefail`, quote everything, no `eval`, prefer `[[ ]]`.
- **Embedded Python:** stdlib only, 3.8-compatible. No `pip install` deps.
- **Network errors:** must flow through the `HubUnavailable` exception so
  the watch loop's error banner triggers correctly. Never let raw
  `urllib.error.URLError` escape `get()`.
- **TUI rendering:** new output must respect the `T.use` colour toggle,
  the computed `W` width, and the flicker-free `emit()` path (no
  `\033[2J` clear-screen).

## Where the brand canon lives

- README has the user-facing pitch.
- This file has the agent-facing rules.
- CONTRIBUTING has the human-contributor flow.
- SECURITY has the disclosure path.

Update all four when the relevant area changes. Don't put rules in one
that should live in another.
