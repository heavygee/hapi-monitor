#!/usr/bin/env bash
# test/update-snapshots.sh - regenerate test/snapshots/*.txt from current code.
#
# Run this AFTER an intentional rendering change. Always:
#   1. git diff test/snapshots/ - eyeball every changed line
#   2. Confirm each delta matches the behavior you intended
#   3. Commit the snapshot updates with the code change
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash "$HERE/test/render-snapshot.sh" update
