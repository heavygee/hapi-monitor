#!/usr/bin/env bash
# Extract the embedded Python from src/hapi-monitor.sh and syntax-check it.
# Single source of truth shared between `npm run lint:py` and the CI
# python-syntax job. Previously these two were divergent and `npm run
# lint:py` failed under dash (process substitution) AND extracted the
# wrong text on bash (awk pattern matched the heredoc terminator only).
# See #9.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$HERE/src/hapi-monitor.sh"

if [[ ! -f "$SRC" ]]; then
  echo "lint:py: cannot find $SRC" >&2
  exit 1
fi

TMP="$(mktemp --suffix=.py)"
trap 'rm -f "$TMP"' EXIT

awk '
  /<<.PY.$/        { inside=1; next }
  inside && /^PY$/ { inside=0; next }
  inside           { print }
' "$SRC" > "$TMP"

lines=$(wc -l < "$TMP")
if [[ "$lines" -lt 100 ]]; then
  echo "lint:py: extracted Python looks too small ($lines lines) - heredoc markers may have moved" >&2
  head -20 "$TMP" >&2
  exit 1
fi

python3 -m py_compile "$TMP"
echo "embedded Python parses cleanly ($lines lines)"
