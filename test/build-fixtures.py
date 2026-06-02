#!/usr/bin/env python3
"""Generate test/fixtures/*.json from a compact in-script spec.

Run after intentionally changing fixture shape:

    python3 test/build-fixtures.py

Then regenerate snapshots:

    bash test/update-snapshots.sh
"""
import json
import os
import sys
from pathlib import Path

FIXTURE_DIR = Path(__file__).parent / "fixtures"
FIXTURE_DIR.mkdir(parents=True, exist_ok=True)

NOW_ISO = "2026-06-02T18:00:00+00:00"
NOW_EPOCH = 1780423200
NOW_MS = NOW_EPOCH * 1000

BUILDS = {
    "appVersionSource": "0.1.1",
    "protocolVersion": "1",
    "gitCommit": "abc1234",
    "gitBranch": "main",
    "gitDirty": False,
    "cliVersion": "0.1.1",
    "bunVersion": "1.2.0",
    "hubService": {"ActiveState": "active", "MainPID": "1001"},
    "runnerService": {"ActiveState": "active", "MainPID": "1002"},
    "web": {
        "distBundle": "index-abc1234.js",
        "distBuiltAt": "2026-06-02 17:00",
        "embeddedBundle": "index-abc1234.js",
        "embeddedGeneratedAt": "2026-06-02 17:00",
        "bundlesMatch": True,
        "embeddedStale": False,
    },
    "machines": [
        {
            "host": "hub1",
            "cliVersion": "0.1.0",
            "libDir": "/opt/hapi",
            "runnerStatus": "running",
            "runnerPid": "2001",
            "runnerPort": "8765",
        }
    ],
}


def row(
    status,
    sid,
    flavor="cursor",
    project="acme",
    path=None,
    thinking_min_ago=None,
    updated_min_ago=0,
    model_tier="$",
    model_label="GPT-5",
    note=None,
    pending=0,
    host_pid=4242,
    agent_id=None,
    machine_id="hub1",
    lifecycle="active",
    procs=None,
):
    """Build one row dict matching gather_rows() output schema."""
    if path is None:
        path = f"/home/dev/{project}"
    if agent_id is None:
        agent_id = f"agent-{sid[:8]}"
    thinking_at = 0
    if thinking_min_ago is not None:
        thinking_at = NOW_MS - thinking_min_ago * 60_000
    updated_at = NOW_MS - updated_min_ago * 60_000
    return {
        "status": status,
        "sid": sid,
        "sid8": sid[:8],
        "flavor": flavor,
        "path": path,
        "machineId": machine_id,
        "project": project,
        "thinking": status == "WORKING" or status == "STUCK?",
        "thinkingAt": thinking_at,
        "lifecycle": lifecycle,
        "hostPid": host_pid,
        "agentSessionId": agent_id,
        "modelTier": model_tier,
        "modelLabel": model_label,
        "note": note,
        "procs": procs or [],
        "pending": pending,
        "recencyAt": max(thinking_at, updated_at),
        "updatedAt": updated_at,
    }


def make_sid(byte):
    """Deterministic UUID-shaped id from a single byte."""
    s = f"{byte:02x}" * 16
    return f"{s[0:8]}-{s[8:12]}-{s[12:16]}-{s[16:20]}-{s[20:32]}"


def write_fixture(name, payload):
    out = FIXTURE_DIR / f"{name}.json"
    out.write_text(json.dumps(payload, indent=2) + "\n")
    print(f"  wrote {out.relative_to(Path.cwd()) if out.is_relative_to(Path.cwd()) else out}")


FIXTURES = {}


# 1. minimal: single OK row. Smoke test that the table renders at all.
FIXTURES["minimal"] = {
    "now": NOW_ISO,
    "now_epoch": NOW_EPOCH,
    "show_inactive": False,
    "cursor_sid": None,
    "builds": BUILDS,
    "chart": {"samples": [[0, 0]], "peak": 0},
    "rows": [
        row("OK", make_sid(0x10), flavor="cursor", project="acme", updated_min_ago=1),
    ],
}


# 2. alerts: WORKING + STUCK? + ZOMBIE so attention section renders with
# all three card types. Catches regressions in the attention-card path,
# status badge colors, and modelTier/Label rendering.
FIXTURES["alerts"] = {
    "now": NOW_ISO,
    "now_epoch": NOW_EPOCH,
    "show_inactive": False,
    "cursor_sid": None,
    "builds": BUILDS,
    "chart": {"samples": [[1, 2], [1, 2], [2, 2]], "peak": 2},
    "rows": [
        row("WORKING", make_sid(0x20), flavor="claude", project="bots",
            thinking_min_ago=3, model_tier="$", model_label="Sonnet"),
        row("STUCK?", make_sid(0x21), flavor="cursor", project="legacy",
            thinking_min_ago=25, model_tier="?", model_label="auto",
            note="thinking 25m > stuck>20m"),
        row("ZOMBIE", make_sid(0x22), flavor="codex", project="ghost",
            updated_min_ago=120, host_pid=None,
            note="active but no runner pid"),
        row("OK", make_sid(0x23), flavor="cursor", project="acme",
            updated_min_ago=2),
        row("OK", make_sid(0x24), flavor="cursor", project="acme",
            updated_min_ago=4),
    ],
}


# 3. idle-only: ten OK rows, no alerts. Catches regressions in the IDLE
# section's column header, row layout, and "no attention right now" copy.
FIXTURES["idle-only"] = {
    "now": NOW_ISO,
    "now_epoch": NOW_EPOCH,
    "show_inactive": False,
    "cursor_sid": None,
    "builds": BUILDS,
    "chart": {"samples": [[0, 0]] * 8, "peak": 0},
    "rows": [
        row("OK", make_sid(0x30 + i), flavor=["cursor", "claude", "codex"][i % 3],
            project=f"proj-{i:02d}", updated_min_ago=(i + 1) * 2)
        for i in range(10)
    ],
}


# 4. inactive-toggle: 3 active rows + 30 INACTIVE rows with show_inactive=True.
# This is the direct regression for #8 (INACTIVE rows overflowing the viewport
# and pushing the header off-screen). The snapshot MUST stay within LINES=40
# and MUST contain a "+N below" marker proving the section was windowed,
# not dumped wholesale.
FIXTURES["inactive-toggle"] = {
    "now": NOW_ISO,
    "now_epoch": NOW_EPOCH,
    "show_inactive": True,
    "cursor_sid": None,
    "builds": BUILDS,
    "chart": {"samples": [[1, 1], [1, 1], [1, 1]], "peak": 1},
    "rows": (
        [row("OK", make_sid(0x40 + i), flavor="cursor",
             project=f"live-{i}", updated_min_ago=i + 1)
         for i in range(3)]
        + [row("INACTIVE", make_sid(0x50 + i), flavor="cursor",
               project=f"dead-{i:02d}", updated_min_ago=300 + i,
               lifecycle="inactive", host_pid=None)
           for i in range(30)]
    ),
}


# 5. chart-overlap: working_count == peak_count for every sample. This is
# the direct regression for #14 (peak line invisible because working line
# overdrew it). With our COL_BOTH fix the snapshot must contain alternating
# green/magenta segments - in --plain mode we still see the line; the
# colored-ANSI variant would show the alternation, but for stable golden
# files we use --plain and assert the line is PRESENT (not blank).
FIXTURES["chart-overlap"] = {
    "now": NOW_ISO,
    "now_epoch": NOW_EPOCH,
    "show_inactive": False,
    "cursor_sid": None,
    "builds": BUILDS,
    "chart": {
        "samples": [[3, 3], [3, 3], [3, 3], [3, 3], [3, 3], [3, 3], [3, 3], [3, 3]],
        "peak": 3,
    },
    "rows": [
        row("WORKING", make_sid(0x61), flavor="cursor", project="alpha",
            thinking_min_ago=2, model_tier="$", model_label="GPT-5"),
        row("WORKING", make_sid(0x62), flavor="claude", project="beta",
            thinking_min_ago=4, model_tier="$", model_label="Sonnet"),
        row("WORKING", make_sid(0x63), flavor="codex", project="gamma",
            thinking_min_ago=6, model_tier="·", model_label="o4-mini"),
        row("OK", make_sid(0x64), flavor="cursor", project="delta",
            updated_min_ago=1),
    ],
}


def main():
    print(f"Writing fixtures to {FIXTURE_DIR}")
    for name, payload in FIXTURES.items():
        write_fixture(name, payload)
    print(f"Done: {len(FIXTURES)} fixtures")
    return 0


if __name__ == "__main__":
    sys.exit(main())
