<!--
  Thanks for the PR! Please fill out the sections below. Empty / nonsense
  templates may be auto-closed.
-->

## Summary

<!-- One paragraph: what's changing and why. -->

## Linked issue

Fixes #<!-- issue number -->

<!-- If there's no linked issue and this isn't a trivial doc fix, please open
     one first per CONTRIBUTING.md. -->

## How to verify

<!-- Steps a reviewer can run locally. Include exact commands and what they
     should see. -->

- [ ] `shellcheck src/hapi-monitor.sh scripts/build-plotter.sh` clean
- [ ] `bash scripts/build-plotter.sh` still compiles
- [ ] `node bin/hapi-monitor.js --help` shows the change (if user-facing)
- [ ] `bash test/smoke.sh` passes
- [ ] Docs updated (`README.md`, `--help`, `CHANGELOG.md`)

## Risk / blast radius

<!-- Who's affected if this misbehaves? Just my machine? All users on upgrade?
     New users only? -->

## Screenshots / terminal recordings (optional)

<!-- For TUI changes — `asciinema rec` or a copy-paste from your terminal. -->
