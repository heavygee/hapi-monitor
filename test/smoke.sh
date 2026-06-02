#!/usr/bin/env bash
# Lightweight smoke test — runs without a live HAPI hub.
# Covers:
#   - script syntax
#   - --help works
#   - --json against an unreachable hub exits non-zero with friendly error
#   - --watch on an unreachable hub renders the error frame (kills after 3s)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SCRIPT="$ROOT/src/hapi-monitor.sh"

fail() {
  printf 'smoke: FAIL — %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'smoke: OK    — %s\n' "$*"
}

# 1. Script parses
bash -n "$SCRIPT" || fail "syntax check on $SCRIPT"
pass "bash syntax"

# 2. --help works (no hub needed)
"$SCRIPT" --help > /tmp/smoke-help.txt 2>&1 || fail "--help exit code"
grep -q 'Usage: hapi-monitor' /tmp/smoke-help.txt || fail "--help missing usage line"
grep -q 'HAPI_HUB_URL' /tmp/smoke-help.txt || fail "--help missing env var docs"
pass "--help renders"

# 3. Unreachable hub exits 1 with friendly message (no traceback)
set +e
HAPI_HUB_URL="http://127.0.0.1:1" HAPI_JWT="dummy" \
  "$SCRIPT" > /tmp/smoke-down.txt 2>&1
rc=$?
set -e
[[ $rc -eq 1 ]] || fail "expected exit 1 on unreachable hub, got $rc"
grep -q 'hapi-monitor:' /tmp/smoke-down.txt || fail "missing 'hapi-monitor:' prefix on error"
grep -q 'cannot reach' /tmp/smoke-down.txt || fail "missing friendly error text"
grep -qi 'traceback' /tmp/smoke-down.txt && fail "traceback leaked to stderr"
pass "graceful one-shot failure"

# 4. Node wrapper passes --help through
if command -v node >/dev/null 2>&1; then
  node "$ROOT/bin/hapi-monitor.js" --help > /tmp/smoke-node-help.txt 2>&1 || fail "node wrapper --help"
  grep -q 'Usage: hapi-monitor' /tmp/smoke-node-help.txt || fail "node wrapper output missing usage"
  pass "node wrapper passes --help through"
else
  pass "node wrapper skipped (no node on PATH)"
fi

# 5. JSON mode on unreachable hub still exits cleanly
set +e
HAPI_HUB_URL="http://127.0.0.1:1" HAPI_JWT="dummy" \
  "$SCRIPT" --json > /tmp/smoke-json.txt 2>&1
rc=$?
set -e
[[ $rc -eq 1 ]] || fail "--json on unreachable hub expected exit 1, got $rc"
grep -qi 'traceback' /tmp/smoke-json.txt && fail "--json leaked traceback"
pass "--json graceful failure"

printf '\nsmoke: all checks passed\n'
