#!/usr/bin/env bash
# Build the native AGENTS chart renderer (optional; auto-built by hapi-monitor.sh when cc exists).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SRC="$ROOT/src/plotter/hapi-sessions-plot.c"
OUT="${HAPI_SESSIONS_PLOT:-$ROOT/src/plotter/hapi-sessions-plot}"
cc -O2 -Wall -Wextra -o "$OUT" "$SRC"
echo "built: $OUT"
