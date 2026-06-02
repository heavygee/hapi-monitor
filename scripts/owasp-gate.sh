#!/usr/bin/env bash
# Local OWASP SAST gate - mirrors CI job owasp-sast in .github/workflows/ci.yml.
# Run before pushing to catch findings without waiting on Actions.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SEMGREP_IMAGE="${SEMGREP_IMAGE:-semgrep/semgrep:1.122.0}"
CONFIG=(
  --config p/owasp-top-ten
  --config p/javascript
  --config p/python
  --config p/secrets
  --config security/semgrep/
)

run_docker() {
  docker run --rm \
    -v "$ROOT:/src" \
    -w /src \
    "$SEMGREP_IMAGE" \
    semgrep scan \
      "${CONFIG[@]}" \
      --metrics=off \
      --error \
      /src
}

run_local() {
  if ! command -v semgrep >/dev/null 2>&1; then
    echo "Install semgrep (pipx install semgrep) or set up Docker for the pinned image." >&2
    exit 1
  fi
  semgrep scan "${CONFIG[@]}" --metrics=off --error .
}

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  run_docker
else
  run_local
fi

echo "OWASP SAST gate: OK"
