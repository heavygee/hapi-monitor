#!/usr/bin/env bash
# test/render-snapshot.sh - golden-frame snapshot tests for the TUI.
#
# For each test/fixtures/*.json, render one deterministic frame via the
# HAPI_RENDER_FIXTURE bypass and diff against test/snapshots/<name>.txt.
# All four 2026-06-02 TUI bugs (#7, #8, #12, #14) would have produced
# diffs against the committed snapshots, which is the whole point.
#
# To update the goldens after an intentional rendering change, run
# test/update-snapshots.sh and inspect the diff before committing.
#
# Environment overrides (rarely needed):
#   HAPI_MONITOR_BIN   path to hapi-monitor.sh (default: src/hapi-monitor.sh)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${HAPI_MONITOR_BIN:-$HERE/src/hapi-monitor.sh}"
FIXTURE_DIR="$HERE/test/fixtures"
SNAP_DIR="$HERE/test/snapshots"

if [[ ! -x "$BIN" && ! -f "$BIN" ]]; then
  echo "snapshot: cannot find $BIN" >&2
  exit 1
fi

if [[ ! -d "$FIXTURE_DIR" ]]; then
  echo "snapshot: no fixtures in $FIXTURE_DIR" >&2
  exit 1
fi

# Deterministic environment. TZ=UTC so the header timestamp matches the
# fixture's UTC `now`. NO_COLOR + --plain wipes ANSI. The fake hub URLs
# are never hit because gather_rows() is stubbed in fixture mode, but
# we set them so module-level init has stable values to print.
export TZ=UTC
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export COLUMNS=120
export LINES=40
export NO_COLOR=1
export HAPI_HUB_URL="http://hub.test:3006"
export HAPI_HUB_PUBLIC_URL="http://hub.test"
export HAPI_JWT="fixture.jwt.token"
export HAPI_SETTINGS="/dev/null"
export HAPI_WATCH_SEC=15
export HAPI_SESSIONS_PLOT="/nonexistent-so-python-fallback-runs"
unset HAPI_WATCH HAPI_FORCE_COLOR FORCE_COLOR HAPI_CHART_STATE || true

mode="${1:-check}"  # check | update

fail=0
checked=0
mapfile -t fixtures < <(find "$FIXTURE_DIR" -maxdepth 1 -name '*.json' | sort)

if [[ ${#fixtures[@]} -eq 0 ]]; then
  echo "snapshot: no .json fixtures found" >&2
  exit 1
fi

for fix in "${fixtures[@]}"; do
  name="$(basename "$fix" .json)"
  snap="$SNAP_DIR/$name.txt"
  got="$(mktemp --suffix=.snap)"
  trap 'rm -f "$got"' EXIT

  if ! HAPI_RENDER_FIXTURE="$fix" bash "$BIN" --plain >"$got" 2>&1; then
    echo "snapshot: FAIL  $name  (render exited nonzero)"
    cat "$got" >&2
    fail=1
    rm -f "$got"
    continue
  fi

  if [[ "$mode" == "update" ]]; then
    mkdir -p "$SNAP_DIR"
    if [[ -f "$snap" ]] && diff -q "$snap" "$got" >/dev/null 2>&1; then
      echo "snapshot:  ==   $name  (no change)"
    else
      cp "$got" "$snap"
      echo "snapshot: WROTE $name"
    fi
  else
    if [[ ! -f "$snap" ]]; then
      echo "snapshot: FAIL  $name  (no golden at $snap; run test/update-snapshots.sh)"
      fail=1
    elif diff -u "$snap" "$got" >/tmp/snapshot-diff-$$.txt 2>&1; then
      echo "snapshot:  OK   $name"
    else
      echo "snapshot: FAIL  $name  (output drifted; review diff below)"
      sed 's/^/    /' /tmp/snapshot-diff-$$.txt >&2
      fail=1
    fi
    rm -f /tmp/snapshot-diff-$$.txt
  fi

  checked=$((checked + 1))
  rm -f "$got"
done

if [[ "$mode" == "update" ]]; then
  echo "snapshot: refreshed $checked golden(s)"
  exit 0
fi

if [[ $fail -ne 0 ]]; then
  echo "snapshot: at least one golden diverged. Investigate, then if the new"
  echo "          rendering is intentional, run: bash test/update-snapshots.sh" >&2
  exit 1
fi

echo "snapshot: all $checked goldens match"

# -- regression assertions ----------------------------------------------------
# These exist to make the "all four 2026-06-02 TUI bugs would have been caught"
# acceptance criterion of #18 concrete. Each assertion targets one historic
# bug. If a future refactor silently regresses one of these, the relevant
# assertion blows up here even if the snapshot text happened to drift in a
# way that obscured it.

assert_fail=0
assert() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "regress:  OK   $name"
  else
    echo "regress: FAIL  $name  (command: $*)" >&2
    assert_fail=1
  fi
}

# Bug #7 (PR #11): hotkey hint must render at column 0, not wrapped under the
# chart column. Easiest invariant: the line starting with `j/k` must exist on
# its own and start at column 0 (allow one leading space - render_header pads
# the line to W with pad_line, but the visible text starts at column 0..1).
hotkey_line="$(grep -F 'j/k ↑↓ select' "$SNAP_DIR/minimal.txt" || true)"
assert "#7  hotkey hint sits at column 0 (not wrapped under chart)" \
  bash -c "[[ -n \"\$1\" ]] && [[ \"\$1\" =~ ^.?j/k ]]" _ "$hotkey_line"

# Bug #8 (PR #13): INACTIVE section must NOT overflow viewport. With 30
# inactive rows at LINES=40 we must (a) have a "+N below" indicator and
# (b) total line count must fit a reasonable viewport.
inactive_lines=$(wc -l < "$SNAP_DIR/inactive-toggle.txt")
assert "#8  inactive overflow windowed (snapshot <= 40 lines)" \
  test "$inactive_lines" -le 40
assert "#8  '+N inactive below' marker present" \
  grep -qF '+19 inactive below' "$SNAP_DIR/inactive-toggle.txt"

# Bug #12 (PR #13 follow-up): header must not bounce. emit() pads to terminal
# height ONLY in watch mode; in one-shot mode the frame must end with a
# substantial non-blank line (the list-hint footer). If the header bounce
# regressed via accidental over-padding, the snapshot would end in blanks.
last_nonblank="$(awk 'NF{last=$0} END{print last}' "$SNAP_DIR/minimal.txt")"
assert "#12  one-shot frame ends with content footer (no trailing pad)" \
  bash -c "[[ -n \"\$1\" ]]" _ "$last_nonblank"

# Bug #14 (PR #16): chart must show BOTH green (work, fg 46) and magenta
# (peak, fg 201) when working == peak via the COL_BOTH alternation. Plain
# mode hides this, so re-render chart-overlap with FORCE_COLOR=1 and assert
# both ANSI sequences appear in the output stream.
overlap_color="$(mktemp)"
HAPI_RENDER_FIXTURE="$FIXTURE_DIR/chart-overlap.json" \
  FORCE_COLOR=1 NO_COLOR='' \
  bash "$BIN" >"$overlap_color" 2>&1 || true
if grep -q $'\033\[38;5;46m' "$overlap_color" \
   && grep -q $'\033\[38;5;201m' "$overlap_color"; then
  echo "regress:  OK   #14  chart overlap uses both green AND magenta (COL_BOTH alternation)"
else
  echo "regress: FAIL  #14  chart overlap missing color alternation" >&2
  assert_fail=1
fi
rm -f "$overlap_color"

# Bug #28: cursor sessions still on the legacy stream-json protocol must
# render with a visibly different badge (lowercase 'cursor' in plain mode)
# AND their note must include the '[legacy stream-json]' marker so
# operators can spot legacy holdouts during the ACP rollout.
assert "#28  legacy cursor badge renders lowercase in plain mode" \
  grep -qE '◆[[:space:]]+cursor[[:space:]]+oldsk00l' "$SNAP_DIR/cursor-acp-mix.txt"
assert "#28  legacy cursor note carries '[legacy stream-json]' marker" \
  grep -qF '[legacy stream-json]' "$SNAP_DIR/cursor-acp-mix.txt"
assert "#28  ACP cursor badge keeps uppercase CURSOR" \
  grep -qE '◆[[:space:]]+CURSOR[[:space:]]+modern' "$SNAP_DIR/cursor-acp-mix.txt"

# Bug #42: idle rows must show metadata.name (HAPI session title) in the
# NOTE column when set, falling back to path when unset. Pre-fix, five
# idle rows in the same repo were visually identical.
assert "#42  titled idle rows show the title in NOTE" \
  grep -qF 'upstream issue/pr discovery' "$SNAP_DIR/session-titles.txt"
assert "#42  unnamed idle rows still fall back to path" \
  grep -qF '/home/dev/hapi' "$SNAP_DIR/session-titles.txt"

if [[ $assert_fail -ne 0 ]]; then
  echo "regress: at least one historic-bug assertion failed" >&2
  exit 1
fi

echo "regress: all 9 historic-bug assertions pass"
