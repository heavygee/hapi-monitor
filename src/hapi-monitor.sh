#!/usr/bin/env bash
# hapi-monitor — terminal session monitor for a HAPI hub.
# BBS-edition styling, nvtop-style chart, sticky-cursor agent table.
#
# Usage:
#   hapi-monitor                # all sessions
#   hapi-monitor jellybot       # filter path/flavor/id substring
#   hapi-monitor --json
#   hapi-monitor --watch        # refresh every 1s (HAPI_WATCH_SEC to tune)
#
# Trust model:
#   OK       active, not thinking, runner PID alive
#   WORKING  active, thinking, agent/runner alive, thinking < STUCK_MIN minutes
#   STUCK?   thinking too long OR hub says active but PIDs missing
#   ZOMBIE   active but no runner/agent process
#   IDLE     inactive session (listed only with --all)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# HAPI repo for build identifiers — env wins, then well-known active worktree,
# then ~/coding/hapi mirror. Anything that does not exist falls through.
resolve_hapi_repo() {
  local cand
  for cand in "${HAPI_REPO:-}" "$HOME/coding/hapi-active" "$HOME/coding/hapi-driver" "$HOME/coding/hapi"; do
    [[ -n "$cand" && -d "$cand" ]] && { printf '%s' "$cand"; return; }
  done
  printf '%s' "$HOME/coding/hapi"
}
ROOT="$(resolve_hapi_repo)"
# Native plotter lives alongside the script in src/plotter/. We auto-build it
# the first time we see `cc` if a prebuilt binary isn't around; otherwise the
# Python fallback (less crisp, identical data) takes over.
HAPI_SESSIONS_PLOT="${HAPI_SESSIONS_PLOT:-$SCRIPT_DIR/plotter/hapi-sessions-plot}"
ensure_hapi_sessions_plot() {
  [[ -x "$HAPI_SESSIONS_PLOT" ]] && return 0
  [[ -f "$SCRIPT_DIR/plotter/hapi-sessions-plot.c" ]] || return 1
  command -v cc >/dev/null 2>&1 || return 1
  cc -O2 -Wall -Wextra -o "$HAPI_SESSIONS_PLOT" "$SCRIPT_DIR/plotter/hapi-sessions-plot.c" 2>/dev/null
}
ensure_hapi_sessions_plot || true
export HAPI_SESSIONS_PLOT
SETTINGS="${HAPI_SETTINGS:-$HOME/.hapi/settings.json}"
HUB="${HAPI_HUB_URL:-http://127.0.0.1:3006}"
STUCK_MIN="${HAPI_STUCK_MINUTES:-20}"
JSON=0
WATCH=0
WATCH_SEC="${HAPI_WATCH_SEC:-1}"
FILTER=""
ALL=0
BACKUPS=0
PLAIN=0

usage() {
  cat <<'EOF'
Usage: hapi-monitor [--json] [--watch] [--all] [--backups] [--plain] [filter]

  filter     substring match on path, flavor, session id, or agent session id
  --backups  append borg / system-backup process snapshot (local machine)
  --plain    no ANSI colors (also respects NO_COLOR=1)
  --watch    in-place refresh (alternate screen, no full clear flash)
  --all      show INACTIVE (disconnected) agents on launch.
             Default hides them but they remain in the total count.
             Press 'i' in --watch to toggle visibility live.

Environment:
  HAPI_HUB_URL          API target (default http://127.0.0.1:3006).
                        Used for actual HTTP calls.
  HAPI_HUB_PUBLIC_URL   display-only canonical hub URL. Defaults to the
                        Tailscale Service form (https://hapi.<magicdns-suffix>)
                        when 'tailscale' is available, else falls back to
                        HAPI_HUB_URL. Cached in $TMPDIR/hapi-hub-public-url.cache.
  HAPI_JWT              short-lived hub JWT; if set, skip the settings lookup
  HAPI_SETTINGS         path to JSON file containing {"cliApiToken": "..."}
                        (default: ~/.hapi/settings.json)
  HAPI_REPO             repo root for build identifiers (default: ~/coding/hapi-active or ~/coding/hapi)
  HAPI_STUCK_MINUTES    thinking longer than this → STUCK? (default 20)
  HAPI_WATCH_SEC        refresh interval for --watch (default 1; supports fractions e.g. 0.5)
  HAPI_CHART_STATE      sparkline history file (--watch; default $TMPDIR/hapi-monitor-chart.$$)
  HAPI_SESSIONS_PLOT    native chart binary (default: src/plotter/hapi-sessions-plot; auto-built if cc present)
  HAPI_HEALTH_LEGACY_CARDS  1 = old 7-line bordered cards for WORKING/STUCK/ZOMBIE
  HAPI_HEALTH_IDLE_MAX  cap idle rows (default: fit terminal below header + alerts)
  NO_COLOR / HAPI_FORCE_COLOR / FORCE_COLOR
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) JSON=1; shift ;;
    --watch) WATCH=1; shift ;;
    --all) ALL=1; shift ;;
    --backups) BACKUPS=1; shift ;;
    --plain) PLAIN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) FILTER="$1"; shift ;;
  esac
done

report() {
  # Auth + retry now live in Python so the watch loop survives a hub bounce
  # and we don't need curl. Settings file location is HAPI_SETTINGS.
  HAPI_SETTINGS_PATH="$SETTINGS" HAPI_HUB_URL="$HUB" \
    python3 - "$ROOT" "$STUCK_MIN" "$FILTER" "$JSON" "$ALL" "$BACKUPS" "$PLAIN" <<'PY'
import json, os, re, shutil, signal, socket, subprocess, sys, time
import urllib.error, urllib.request
from datetime import datetime, timezone
from pathlib import Path

# Don't crash on `| head` or other broken-pipe consumers.
try:
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
except (AttributeError, ValueError):
    pass

repo = Path(sys.argv[1])
stuck_min = int(sys.argv[2])
filt = sys.argv[3].lower()
as_json = sys.argv[4] == '1'
show_all = sys.argv[5] == '1'
# show_inactive is the live display toggle (hotkey 'i' flips it in --watch).
# Defaults to whatever the launch flag asked for; INACTIVE sessions are always
# gathered now so the total count includes them whether displayed or not.
show_inactive = show_all
show_backups = sys.argv[6] == '1'
force_plain = sys.argv[7] == '1'
hub = os.environ.get('HAPI_HUB_URL', 'http://127.0.0.1:3006')
settings_path = Path(os.environ.get('HAPI_SETTINGS_PATH') or os.environ.get('HAPI_SETTINGS') or (str(Path.home() / '.hapi/settings.json')))

# ── Auth + HTTP (everything that can talk to the hub goes through here) ────

class HubUnavailable(RuntimeError):
    """Raised when the hub can't be reached, refused auth, or returned junk.
    Carries an operator-friendly message in str(); watch loop renders it as
    a banner, one-shot mode prints it to stderr."""

def _fetch_jwt():
    """Trade the cliApiToken in settings.json for a short-lived JWT.

    Two ways the operator can satisfy this:
      1. set HAPI_JWT in the environment (bypasses settings entirely)
      2. drop ~/.hapi/settings.json with {"cliApiToken": "..."} in it
    Override the file location with HAPI_SETTINGS.
    """
    env_jwt = os.environ.get('HAPI_JWT')
    if env_jwt:
        return env_jwt
    if not settings_path.exists():
        raise HubUnavailable(
            f'no JWT and no settings file at {settings_path}.\n'
            f'  fix: set HAPI_JWT, or create {settings_path} containing\n'
            f'  {{"cliApiToken": "<token from hub admin>"}}'
        )
    try:
        cli_token = (json.loads(settings_path.read_text()).get('cliApiToken') or '').strip()
    except (OSError, json.JSONDecodeError) as e:
        raise HubUnavailable(f'cannot parse {settings_path}: {e}')
    if not cli_token:
        raise HubUnavailable(f'no "cliApiToken" key in {settings_path}')
    payload = json.dumps({'accessToken': cli_token}).encode()
    req = urllib.request.Request(
        f'{hub}/api/auth', data=payload,
        headers={'Content-Type': 'application/json'},
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            data = json.load(r)
    except urllib.error.HTTPError as e:
        raise HubUnavailable(f'hub auth rejected: HTTP {e.code} at {hub}/api/auth')
    except urllib.error.URLError as e:
        raise HubUnavailable(f'cannot reach {hub}/api/auth: {e.reason}')
    except (socket.timeout, TimeoutError) as e:
        raise HubUnavailable(f'auth timed out at {hub}/api/auth: {e}')
    except (json.JSONDecodeError, OSError) as e:
        raise HubUnavailable(f'invalid auth response from {hub}: {e}')
    jwt = (data.get('token') or '').strip()
    if not jwt:
        raise HubUnavailable(f'hub auth response missing "token" field: {data!r}')
    return jwt

_TOKEN_CACHE = {'jwt': None}

def _get_token():
    if _TOKEN_CACHE['jwt']:
        return _TOKEN_CACHE['jwt']
    _TOKEN_CACHE['jwt'] = _fetch_jwt()
    return _TOKEN_CACHE['jwt']

def _invalidate_token():
    _TOKEN_CACHE['jwt'] = None
# Display-only URL: what the operator should hand someone if they ask
# 'where is the hub?'. Defaults to the canonical Tailscale Service URL
# when detectable, falls back to the local API URL. The API client still
# uses `hub` for low-latency local hits.
def _detect_hub_public(local_hub):
    override = os.environ.get('HAPI_HUB_PUBLIC_URL')
    if override:
        return override
    cache = Path(os.environ.get('TMPDIR', '/tmp')) / 'hapi-hub-public-url.cache'
    try:
        if cache.exists() and (time.time() - cache.stat().st_mtime) < 3600:
            val = cache.read_text().strip()
            if val:
                return val
    except OSError:
        pass
    try:
        out = subprocess.run(
            ['tailscale', 'status', '--json', '--peers=false'],
            capture_output=True, text=True, timeout=2,
        )
        if out.returncode == 0:
            suffix = (json.loads(out.stdout).get('MagicDNSSuffix') or '').strip()
            if suffix:
                # We don't probe the URL here (would add startup latency); the
                # JSON-defined svc:hapi is the canonical name in this tailnet.
                url = f'https://hapi.{suffix}'
                try:
                    cache.write_text(url)
                except OSError:
                    pass
                return url
    except (FileNotFoundError, subprocess.TimeoutExpired, json.JSONDecodeError, OSError):
        pass
    return local_hub

hub_public = _detect_hub_public(hub)
term_w = shutil.get_terminal_size((100, 40)).columns
watch_mode = os.environ.get('HAPI_WATCH') == '1'
watch_redraw = os.environ.get('HAPI_WATCH_REDRAW') == '1'

W = max(72, min(term_w, 120))

# ── ANSI / BBS chrome ────────────────────────────────────────────────────────

class T:
    """Retro terminal paint box. Respects NO_COLOR unless FORCE_COLOR overrides."""
    _force = os.environ.get('FORCE_COLOR') or os.environ.get('HAPI_FORCE_COLOR')
    _no = os.environ.get('NO_COLOR') and not _force
    use = (sys.stdout.isatty() or _force) and not force_plain and not _no

    @staticmethod
    def wrap(*parts):
        return ''.join(parts) if T.use else ''

    R   = property(lambda s: T.wrap('\033[0m'))
    B   = property(lambda s: T.wrap('\033[1m'))
    DIM = property(lambda s: T.wrap('\033[2m'))
    BL  = property(lambda s: T.wrap('\033[5m') if T.use else '')

    def fg(self, n): return T.wrap(f'\033[38;5;{n}m')
    def bg(self, n): return T.wrap(f'\033[48;5;{n}m')

t = T()

STATUS_STYLE = {
    'OK':       ('OK',       255, 28,  '●'),   # white on dark green (was invisible: fg46 on bg82)
    'WORKING':  ('WORKING',  255, 23,  '◆'),
    'STUCK?':   ('STUCK?',   255, 52,  '▲'),
    'ZOMBIE':   ('ZOMBIE',   255, 53,  '☠'),
    'INACTIVE': ('INACTIVE', 245, 236, '○'),
}

FLAVOR_STYLE = {
    'cursor': (33, 220),
    'claude': (208, 94),
    'codex':  (141, 99),
}

def c256(fg, bg=None):
    s = t.fg(fg)
    if bg is not None:
        s += t.bg(bg)
    return s

def status_badge(status, blink=False):
    label, fg, bg, glyph = STATUS_STYLE.get(status, ('?', 250, 235, '?'))
    inner = f' {glyph} {label} '
    if status == 'STUCK?' and T.use and blink:
        return f'{t.BL}{c256(fg, bg)}{t.B}{inner}{t.R}'
    if not T.use:
        return inner.strip()
    return f'{c256(fg, bg)}{t.B}{inner}{t.R}'

def flavor_badge(flavor):
    fg, bg = FLAVOR_STYLE.get(flavor, (252, 238))
    inner = f' {flavor.upper():<6} '
    if not T.use:
        return flavor
    return f'{c256(fg, bg)}{t.B}{inner}{t.R}'

def render_legend():
    """Footer key — same colored badges as the main board."""
    if not T.use:
        bits = ['OK', 'WORKING', 'STUCK?', 'ZOMBIE', '|', '$ prem', '· eco', '? auto', '|', '--watch', '--json', '--plain']
        if watch_mode:
            bits += ['LIVE', f'{os.environ.get("HAPI_WATCH_SEC", "15")}s']
        return '  '.join(bits)
    parts = [
        status_badge('OK'),
        status_badge('WORKING'),
        status_badge('STUCK?'),  # no blink in legend
        status_badge('ZOMBIE'),
        f'{t.fg(245)}│{t.R}',
        f'{t.fg(220)}$ premium{t.R}',
        f'{t.fg(245)}· economy{t.R}',
        f'{t.fg(245)}? auto{t.R}',
        f'{t.fg(245)}│{t.R}',
        f'{t.fg(87)}--watch{t.R}',
        f'{t.fg(213)}--json{t.R}',
        f'{t.fg(245)}--plain{t.R}',
    ]
    if watch_mode:
        parts.append(f'{t.fg(51)}{t.B}◉ LIVE{t.R} {t.fg(245)}{os.environ.get("HAPI_WATCH_SEC", "15")}s{t.R}')
    return '  '.join(parts)

def render_list_hint(n_rows, all_rows=None, hidden_inactive=0):
    """Explain the bottom-region row count + toggle state.

    `n_rows` is what's currently visible. `hidden_inactive` is the count of
    INACTIVE sessions filtered out by the toggle; surfaced so the operator
    knows there's more behind the curtain and how to reveal it.

    The table itself paginates within the viewport (j/k to scroll) - we do
    NOT promise "no pagination" here. See render_agent_table for the
    windowing logic.
    """
    total_label = f'{n_rows} sessions'
    if hidden_inactive > 0:
        total_label = f'{n_rows} shown · +{hidden_inactive} inactive hidden'
    elif show_inactive and any(r['status'] == 'INACTIVE' for r in (all_rows or [])):
        total_label = f'{n_rows} sessions (incl inactive)'
    if not T.use:
        toggle = ' · i hide inactive' if show_inactive else ' · i show inactive'
        return f'{total_label} · j/k to scroll · hub {hub_public}{toggle if watch_mode else ""}'
    hint = f'{t.fg(245)}{t.DIM}Σ {total_label} · j/k to scroll'
    if watch_mode:
        hint += f'{t.R}  {t.fg(87)}i{t.R}{t.fg(245)}{t.DIM} {"hide" if show_inactive else "show"} inactive{t.R}'
    else:
        hint += t.R
    return hint

def hr(ch='─', color=240):
    line = ch * W
    return f'{t.fg(color)}{line}{t.R}' if T.use else line

def box_top(title='', color=39):
    pad = W - 4 - len(title)
    left = pad // 2
    right = pad - left
    bar = '═' * W
    if not title:
        return f'{t.fg(color)}╔{bar}╗{t.R}' if T.use else '+' + '-' * W + '+'
    head = f'╔{"═" * left} {title} {"═" * right}╗'
    return f'{t.fg(color)}{t.B}{head}{t.R}' if T.use else head

def box_mid(color=39):
    return f'{t.fg(color)}╠{"═" * W}╣{t.R}' if T.use else '+' + '-' * W + '+'

def box_bot(color=39):
    return f'{t.fg(color)}╚{"═" * W}╝{t.R}' if T.use else '+' + '-' * W + '+'

def side(color=39):
    return f'{t.fg(color)}║{t.R}' if T.use else '|'

def pad_line(text, width=W):
    import re
    vis = re.sub(r'\033\[[0-9;]*m', '', text)
    pad = max(0, width - len(vis))
    return text + ' ' * pad

ANSI_RE = None

def vis_len(text):
    global ANSI_RE
    if ANSI_RE is None:
        import re
        ANSI_RE = re.compile(r'\033\[[0-9;]*m')
    return len(ANSI_RE.sub('', text))

def mk_cell(visible, width, styler=None):
    """Fixed-width cell; optional styler wraps visible text only."""
    vis = (visible or '')[:width]
    vis = vis + (' ' * (width - len(vis)))
    if styler and T.use:
        return styler(vis)
    return vis

# Unified agent table columns (visible widths). Default layout — one row per agent,
# active and idle in the same grid, sorted by status. Set HAPI_HEALTH_LEGACY_CARDS=1
# to revert to the old 7-line bordered cards.
#
# Every cell's visible char count MUST equal its declared width, otherwise the
# header labels drift relative to the data underneath. Sum of cell widths is
# the only number that aligns header to body.
W_GUTTER = 2       # cursor mark (▶ / space)
W_STATUS = 3       # ' ◆ '
W_TYPE = 8         # ' CURSOR ' badge (was FLAVOR)
W_PROJ_T = 11      # 10 chars project + 1 space, NO marquee
W_MODEL_T = 6      # 5 chars abbreviated + 1 space
W_THINK_T = 9      # 'YES 12s ' + space
W_CPU_T = 7        # '99.9% ' + space
W_RAM_T = 7        # '99.9% ' + space

SCROLL_CHARS_PER_SEC = 2  # marquee tick rate (visual speed, not data rate)

# Legacy idle-table widths (kept for legacy card mode references)
W_LEAD = 11
W_PROJ = 24
W_MODEL = 22
W_SID = 8
W_PID = 10

def model_visible(tier, label):
    prefix = {'prem': '$', 'eco': '·', 'unk': '?'}.get(tier, '?')
    return f'{prefix}{label}'[: W_MODEL - 1]


def model_abbrev(label, maxlen=5):
    """Squeeze 'composer-2.5-fast' into 'c2.5f', 'claude-sonnet-4-5' into 'cs4.5'.

    Preserves family + version digits — the bits that distinguish neighbors
    like codex 5.3 vs 5.4 or sonnet 4 vs 4.5.
    """
    if not label or label in ('—', '?'):
        return '—'
    s = label.lower().strip()
    if s == 'auto':
        return 'auto'
    import re as _re
    if 'codex' in s:
        m = _re.search(r'(\d+(?:\.\d+)?)', s)
        return (f'cx{m.group(1)}' if m else 'cx')[:maxlen]
    if s.startswith('composer'):
        m = _re.search(r'composer-?(\d+(?:\.\d+)?)', s)
        suf = 'f' if '-fast' in s else ('l' if '-low' in s else '')
        return (f'c{m.group(1)}{suf}' if m else 'comp')[:maxlen]
    if s.startswith('gpt'):
        m = _re.search(r'gpt-?(\d+(?:\.\d+)?)', s)
        return (f'g{m.group(1)}' if m else 'gpt')[:maxlen]
    if s.startswith('claude'):
        fam_map = {'sonnet': 's', 'haiku': 'h', 'opus': 'o'}
        fam = next((v for k, v in fam_map.items() if k in s), '')
        m = _re.search(r'(\d+)-(\d+)', s)
        if m:
            ver = f'{m.group(1)}.{m.group(2)}'
        else:
            m = _re.search(r'-(\d+)', s)
            ver = m.group(1) if m else ''
        return (f'c{fam}{ver}')[:maxlen]
    return s.replace('-', '').replace('_', '')[:maxlen]


def marquee(text, width, key=''):
    """Wall-clock-deterministic scroll. Same offset across processes at same time."""
    if not text:
        return ' ' * width
    text = str(text).replace('\n', ' ').replace('\r', ' ')
    if len(text) <= width:
        return text + ' ' * (width - len(text))
    spacer = '   '
    ring = text + spacer
    cyc = len(ring)
    phase = (abs(hash(key)) % cyc) if key else 0
    offset = (int(time.time() * SCROLL_CHARS_PER_SEC) + phase) % cyc
    return (ring + ring)[offset:offset + width]

def style_model(vis, tier):
    if tier == 'prem':
        return f'{t.fg(220)}{t.B}{vis[0]}{t.R}{t.fg(252)}{vis[1:]}{t.R}'
    if tier == 'eco':
        return f'{t.fg(245)}{vis}{t.R}'
    return f'{t.fg(245)}{vis}{t.R}'

def render_ok_header():
    if not T.use:
        return f'{"":11}{"PROJECT":<{W_PROJ}}{"MODEL":<{W_MODEL}}{"SID":<{W_SID}}{"RUNNER":<{W_PID}}'
    return (
        f' {t.fg(245)}{t.DIM}'
        f'{"":11}{"PROJECT":<{W_PROJ}}{"MODEL":<{W_MODEL}}{"SID":<{W_SID}}{"RUNNER":<{W_PID}}'
        f'{t.R}'
    )

def truncate_vis(text, max_vis):
    if vis_len(text) <= max_vis:
        return text
    plain = ANSI_RE.sub('', text)
    if len(plain) <= max_vis:
        return text
    return plain[: max(0, max_vis - 1)] + '…'

def pad_vis(text, width):
    return text + (' ' * max(0, width - vis_len(text)))

LOGO_W = 38
HEADER_GAP = 2
CHART_MIN_W = 30
HEADER_ROWS = 10  # logo (1 blank + 9 letters) = chart height = build-box span
DETAIL_ROWS = 3   # rows under the chart for selected-agent detail
CHART_TITLE = 'AGENTS'

def working_count(rows):
    return sum(1 for r in rows if r['status'] == 'WORKING')

def chart_state_path():
    return os.environ.get('HAPI_CHART_STATE') or ''

def load_chart_state():
    path = chart_state_path()
    if not path or not os.path.isfile(path):
        return {'samples': [], 'peak': 0}
    try:
        data = json.loads(Path(path).read_text())
        samples = data.get('samples') or []
        clean = []
        for item in samples:
            if isinstance(item, (list, tuple)) and len(item) >= 2:
                clean.append([int(item[0]), int(item[1])])
        peak = int(data.get('peak') or 0)
        if clean:
            peak = max(peak, max(p for _, p in clean))
        return {'samples': clean, 'peak': peak}
    except Exception:
        return {'samples': [], 'peak': 0}

def save_chart_state(state):
    path = chart_state_path()
    if not path:
        return
    try:
        Path(path).write_text(json.dumps(state))
    except Exception:
        pass

def record_chart_sample(rows):
    """Append (working, peak-so-far) when --watch persists HAPI_CHART_STATE."""
    now = working_count(rows)
    if not (watch_mode and chart_state_path()):
        return {'samples': [[now, now]], 'peak': now}
    state = load_chart_state()
    peak = max(int(state.get('peak') or 0), now)
    samples = list(state.get('samples') or [])
    samples.append([now, peak])
    samples = samples[-512:]
    state = {'samples': samples, 'peak': peak}
    save_chart_state(state)
    return state

# nvtop src/plot.c ACS step plot (UTF-8 corners ┐└┌┘ ─ │ — not braille, not Bezier).
# Names match ncurses ACS: UL/UR/LL/LR refer to the direction of strokes through
# the cell (UL = down + right), NOT the visual corner of a box.
_CH = {
    'H': '─',
    'V': '│',
    'UL': '┌',  # ACS_ULCORNER — strokes go DOWN and RIGHT
    'UR': '┐',  # ACS_URCORNER — strokes go DOWN and LEFT
    'LL': '└',  # ACS_LLCORNER — strokes go UP and RIGHT
    'LR': '┘',  # ACS_LRCORNER — strokes go UP and LEFT
}


class LineCanvas:
    """Character grid; nvtop_line_plot() corner + hold drawing."""

    def __init__(self, width, height):
        self.w = width
        self.h = height
        self.grid = [[None] * width for _ in range(height)]
        self.color = [[None] * width for _ in range(height)]

    def put(self, cx, cy, ch, color):
        if 0 <= cx < self.w and 0 <= cy < self.h:
            self.grid[cy][cx] = ch
            self.color[cy][cx] = color

    def hline(self, x0, x1, cy, color):
        if x0 > x1:
            x0, x1 = x1, x0
        for cx in range(x0, x1 + 1):
            self.put(cx, cy, _CH['H'], color)

    def char_row(self, cy, color_fn):
        out = []
        for cx in range(self.w):
            ch = self.grid[cy][cx]
            if not ch:
                out.append(' ')
                continue
            out.append(color_fn(ch, self.color[cy][cx]))
        return ''.join(out)

def align_scroll_samples(samples, width):
    """Right-align history: new samples enter from the right (nvtop scroll)."""
    if not samples:
        return [None] * width
    if len(samples) >= width:
        return samples[-width:]
    return [None] * (width - len(samples)) + samples

def chart_data_level(rows, data, max_y):
    """Row index from value (0=top), matching nvtop src/plot.c data_level()."""
    increment = max_y / max(rows - 1, 1)
    if increment <= 0:
        return rows - 1
    return int(rows - 1 - round(data / increment))

def chart_y_tick_values(max_y):
    if max_y <= 8:
        return list(range(0, max_y + 1))
    return sorted({0, max_y, max_y // 4, max_y // 2, (3 * max_y) // 4})

def tick_row_for_value(val, max_y, plot_h):
    return chart_data_level(plot_h, val, max_y)

def plot_series_nvtop(canvas, values, max_y, color):
    """Direct port of nvtop src/plot.c nvtop_line_plot() per-metric loop.

    CRITICAL: never paint back at previous columns. The corner glyph each
    iteration places stays put; overpainting it with '─' destroys the
    connection and produces the disconnected look we had before.
    """
    rows = canvas.h
    lvl_before = None
    last_col = None
    for col, val in enumerate(values):
        if val is None:
            continue
        lvl_now = chart_data_level(rows, val, max_y)
        if last_col is None:
            canvas.put(col, lvl_now, _CH['H'], color)
            lvl_before = lvl_now
            last_col = col
            continue
        if col > last_col + 1:
            canvas.hline(last_col + 1, col - 1, lvl_before, color)
        if lvl_before != lvl_now:
            drawing_down = lvl_before < lvl_now
            bottom = lvl_before if drawing_down else lvl_now
            top = lvl_now if drawing_down else lvl_before
            canvas.put(col, bottom, _CH['UR'] if drawing_down else _CH['UL'], color)
            canvas.put(col, top, _CH['LL'] if drawing_down else _CH['LR'], color)
            for r in range(bottom + 1, top):
                canvas.put(col, r, _CH['V'], color)
        else:
            canvas.put(col, lvl_now, _CH['H'], color)
        lvl_before = lvl_now
        last_col = col

def nvtop_line_plot(canvas, series_specs, max_y):
    for spec in series_specs:
        plot_series_nvtop(canvas, spec['values'], max_y, spec['color'])

def chart_time_axis(plot_w, watch_sec, sample_count):
    """Bottom axis: -Ns labels (nvtop style), newest at right (-0s)."""
    line = [' '] * plot_w
    if plot_w < 4:
        return ''.join(line)
    filled = max(1, sample_count)
    total_sec = max(0, (filled - 1) * watch_sec)
    marks = []
    for i in range(4):
        frac = i / 3
        x = int(round(frac * (plot_w - 1)))
        sec = int(round(total_sec * (1 - frac)))
        marks.append((x, '-0s' if sec == 0 else f'-{sec}s'))
    for x, label in sorted(marks, key=lambda m: -m[0]):
        start = max(0, min(x - len(label) + 1, plot_w - len(label)))
        for j, ch in enumerate(label):
            pos = start + j
            if pos < plot_w and line[pos] == ' ':
                line[pos] = ch
    return ''.join(line)

def render_agent_chart_native(state, width, height, now, peak, watch_sec):
    """Prefer compiled hapi-sessions-plot (line chart + nvtop step algorithm)."""
    plot_bin = os.environ.get('HAPI_SESSIONS_PLOT', '')
    if not plot_bin or not os.access(plot_bin, os.X_OK):
        return None
    try:
        proc = subprocess.run(
            [plot_bin],
            input=json.dumps({
                'samples': state.get('samples') or [],
                'peak': peak,
                'now': now,
                'width': width,
                'height': height,
                'watch_sec': watch_sec,
                'plain': not T.use,
            }),
            capture_output=True,
            text=True,
            timeout=5,
        )
    except Exception:
        return None
    if proc.returncode != 0:
        return None
    lines = (proc.stdout or '').splitlines()
    return lines if lines else None

def render_agent_chart(state, width, height):
    """Line step plot (nvtop plot.c algorithm): scroll left, newest on the right."""
    samples = list(state.get('samples') or [])
    peak = int(state.get('peak') or 0)
    now = samples[-1][0] if samples else 0
    watch_sec = max(1, int(os.environ.get('HAPI_WATCH_SEC', '15') or 15))
    native = render_agent_chart_native(state, width, height, now, peak, watch_sec)
    if native is not None:
        while len(native) < height:
            native.insert(0, '')
        return native[:height]
    inner_w = max(28, width - 2)
    vals_all = []
    for item in samples:
        if item is not None:
            vals_all.extend([int(item[0]), int(item[1])])
    max_y = max(1, peak, max(vals_all, default=0))
    ylab_w = max(3, len(str(max_y)))
    plot_w = max(14, inner_w - ylab_w - 1)
    plot_h = max(5, height - 4)
    window = align_scroll_samples(samples, plot_w)
    work_vals = []
    peak_vals = []
    for item in window:
        if item is None:
            work_vals.append(None)
            peak_vals.append(None)
        else:
            work_vals.append(int(item[0]))
            peak_vals.append(int(item[1]))

    color_peak = 'peak'
    color_work = 'work'

    canvas = LineCanvas(plot_w, plot_h)
    nvtop_line_plot(
        canvas,
        [
            {'values': peak_vals, 'color': color_peak},
            {'values': work_vals, 'color': color_work},
        ],
        max_y,
    )

    tick_rows = {}
    for tv in chart_y_tick_values(max_y):
        tick_rows[tick_row_for_value(tv, max_y, plot_h)] = str(tv)

    def line_style(ch, series):
        if not T.use or not series:
            return ch
        if series == color_work:
            return f'{t.fg(46)}{ch}{t.R}'
        if series == color_peak:
            return f'{t.fg(201)}{ch}{t.R}'
        return ch

    def box_row(content_vis):
        cell = pad_vis(content_vis, inner_w)
        return f'{t.fg(141)}│{t.R}{cell}{t.fg(141)}│{t.R}' if T.use else f'|{cell}|'

    lines = []
    title = f' {CHART_TITLE} '
    if T.use:
        title = f'{t.fg(213)}{t.B}{title}{t.R}'
    top = f'┌{title}{"─" * max(0, inner_w - vis_len(title))}┐'
    lines.append(f'{t.fg(141)}{top}{t.R}' if T.use else top)

    # Split the legend: working count anchored to the left axis, peak count
    # right-justified to the chart's inner edge so we don't leave dead space.
    if T.use:
        left_seg = (
            f'{"":>{ylab_w}}{t.fg(245)}┤{t.R} '
            f'{t.fg(46)}──{t.R} {t.fg(220)}working{t.R} {t.fg(245)}{now}{t.R}'
        )
        right_seg = (
            f'{t.fg(201)}──{t.R} {t.fg(201)}peak{t.R} {t.fg(220)}{t.B}{peak}{t.R} '
        )
    else:
        left_seg = f'{"":>{ylab_w}}┤ working {now}'
        right_seg = f'peak {peak} '
    gap = max(2, inner_w - vis_len(left_seg) - vis_len(right_seg))
    leg = left_seg + (' ' * gap) + right_seg
    lines.append(box_row(leg))

    for row_i in range(plot_h):
        y_lbl = tick_rows.get(row_i, '')
        plot_body = canvas.char_row(row_i, line_style)
        if T.use:
            axis = f'{t.fg(245)}{y_lbl:>{ylab_w}}{t.R}{t.fg(245)}┤{t.R}'
            lines.append(box_row(f'{axis}{plot_body}'))
        else:
            lines.append(box_row(f'{y_lbl:>{ylab_w}}┤{plot_body}'))

    n_filled = sum(1 for v in work_vals if v is not None)
    time_body = chart_time_axis(plot_w, watch_sec, n_filled)
    if T.use:
        xaxis = f'{"":>{ylab_w}}{t.fg(245)}┤{t.R}{t.fg(245)}{t.DIM}{time_body}{t.R}'
    else:
        xaxis = f'{"":>{ylab_w}}┤{time_body}'
    lines.append(box_row(xaxis))

    bot = f'└{"─" * inner_w}┘'
    lines.append(f'{t.fg(141)}{bot}{t.R}' if T.use else bot)

    # Pad to height by inserting blank inner rows just below the top border
    # (NOT extra top borders, which used to double up the ┌──┐ line).
    while len(lines) < height:
        blank = pad_vis('', inner_w)
        blank_row = f'{t.fg(141)}│{t.R}{blank}{t.fg(141)}│{t.R}' if T.use else f'|{blank}|'
        lines.insert(1, blank_row)
    return lines[:height]

def build_state_plain_lines(builds, rows):
    git = builds.get('gitBranch') or '?'
    if builds.get('gitCommit'):
        git += f'@{builds["gitCommit"]}'
    if builds.get('gitDirty'):
        git += '*'
    web = builds.get('web') or {}
    if web.get('embeddedStale'):
        sync = 'STALE'
    elif web.get('bundlesMatch') is False:
        sync = 'MISMATCH'
    else:
        sync = 'sync'
    hub_u = builds.get('hubService') or {}
    run_u = builds.get('runnerService') or {}

    counts = {k: 0 for k in STATUS_STYLE}
    for r in rows:
        counts[r['status']] = counts.get(r['status'], 0) + 1
    chips = []
    for key in ('STUCK?', 'ZOMBIE', 'WORKING', 'OK', 'INACTIVE'):
        n = counts.get(key, 0)
        if n == 0:
            continue
        glyph = STATUS_STYLE[key][3]
        chips.append(f'{glyph}{key} {n}')
    summary = ' '.join(chips) if chips else 'none active'

    lines = [
        f'app {builds.get("appVersionSource") or "?"}  p{builds.get("protocolVersion") or "?"}  cli {builds.get("cliVersion") or "?"}',
        f'git {git}',
        f'hub {hub_u.get("ActiveState") or "?"}:{hub_u.get("MainPID") or "—"}  run {run_u.get("ActiveState") or "?"}:{run_u.get("MainPID") or "—"}',
    ]
    if web.get('distBundle'):
        bundle = web['distBundle'].replace('index-', '').replace('.js', '')
        lines.append(f'web {bundle}@{web.get("distBuiltAt") or "?"}  {sync}')
    for m in (builds.get('machines') or [])[:1]:
        lines.append(
            f'{m.get("host") or "?"}  {m.get("runnerStatus") or "?"} pid {m.get("runnerPid") or "—"} :{m.get("runnerPort") or "—"}'
        )
    lines.append(f'sessions {len(rows)}   {summary}')
    return lines

def render_state_panel(builds, rows, width, target_height=None):
    plain = build_state_plain_lines(builds, rows)
    title = 'BUILD + STATE'
    plain = [truncate_vis(ln, width - 4) for ln in plain]
    content_w = max([len(title)] + [len(ln) for ln in plain]) + 2
    inner_w = min(max(28, content_w), width - 2)

    if not T.use:
        out = [title, *plain]
        return [ln[:width] for ln in out]

    title_s = f'{t.fg(141)}{t.B}{title}{t.R}'
    styled = [truncate_vis(title_s, inner_w)]
    styled.append(f'{t.fg(245)}{truncate_vis("─" * min(inner_w - 2, 26), inner_w)}{t.R}')
    for i, ln in enumerate(plain):
        if i == 0:
            styled.append(f'{t.fg(252)}{ln}{t.R}')
        elif ln.startswith('git '):
            styled.append(f'{t.fg(87)}{ln}{t.R}')
        elif ln.startswith('hub '):
            styled.append(f'{t.fg(245)}{ln}{t.R}')
        elif ln.startswith('web '):
            web = builds.get('web') or {}
            if web.get('embeddedStale'):
                col = t.fg(196)
            elif web.get('bundlesMatch') is False:
                col = t.fg(220)
            else:
                col = t.fg(46)
            sync_word = ln.split()[-1]
            head = ln[: ln.rfind(sync_word)]
            styled.append(f'{t.fg(245)}{head}{col}{sync_word}{t.R}')
        elif ln.startswith('sessions '):
            styled.append(f'{t.fg(51)}{t.B}{ln}{t.R}')
        else:
            styled.append(f'{t.fg(245)}{ln}{t.R}')

    out = []
    top = f'┌{"─" * inner_w}┐'
    bot = f'└{"─" * inner_w}┘'
    out.append(f'{t.fg(141)}{top}{t.R}')
    for ln in styled:
        cell = pad_vis(f' {truncate_vis(ln, inner_w - 1)}', inner_w)
        out.append(f'{t.fg(141)}│{t.R}{cell}{t.fg(141)}│{t.R}')
    out.append(f'{t.fg(141)}{bot}{t.R}')
    # Pad to target_height by inserting blank interior rows before the bottom border.
    if target_height and len(out) < target_height:
        blank = pad_vis('', inner_w)
        blank_row = f'{t.fg(141)}│{t.R}{blank}{t.fg(141)}│{t.R}'
        while len(out) < target_height:
            out.insert(len(out) - 1, blank_row)
    return out

def render_header(now_str, builds, rows, selected_row=None):
    pulse_frame = int(time.time()) % 4
    pulse = ['◴', '◷', '◶', '◵'][pulse_frame]
    online = f'{t.fg(46)}{pulse} ONLINE{t.R}' if T.use else 'ONLINE'
    # Logo offset: 1 blank row above + 2 spaces of left padding.
    art_left = [
        '',
        '  ██╗  ██╗   █████╗   ██████╗  ██╗',
        '  ██║  ██║  ██╔══██╗  ██╔══██╗ ██║',
        '  ██║  ██║  ██║  ██║  ██║  ██║ ██║',
        '  ██║  ██║  ██║  ██║  ██║  ██║ ██║',
        '  ███████║  ███████║  ██████╔╝ ██║',
        '  ██╔══██║  ██╔══██║  ██╔═══╝  ██║',
        '  ██║  ██║  ██║  ██║  ██║      ██║',
        '  ██║  ██║  ██║  ██║  ██║      ██║',
        '  ╚═╝  ╚═╝  ╚═╝  ╚═╝  ╚═╝      ╚═╝',
    ]
    grad = [33, 39, 39, 45, 45, 51, 87, 87, 123, 159]
    logo_lines = []
    for i, row in enumerate(art_left):
        col = grad[i % len(grad)]
        logo_lines.append(f'{t.fg(col)}{t.B}{row}{t.R}' if T.use else row)

    chart_state = record_chart_sample(rows)
    right_w = max(32, W - LOGO_W - HEADER_GAP)
    panel_lines = render_state_panel(builds, rows, right_w, target_height=HEADER_ROWS)
    panel_w = max((vis_len(ln) for ln in panel_lines), default=28)
    chart_w = max(CHART_MIN_W, W - LOGO_W - HEADER_GAP - panel_w - HEADER_GAP)
    row_count = max(len(logo_lines), len(panel_lines), HEADER_ROWS)
    chart_lines = render_agent_chart(chart_state, chart_w, row_count)
    # When a row is selected the detail line (SID/AG/RUN) is short and aligns
    # nicely under the chart column. When nothing is selected the detail line
    # is the hotkey hint - too wide for the chart column, so we render it
    # full-width at column 0 to avoid wrapping behind the panels.
    if selected_row:
        detail_lines = render_detail_below_chart(selected_row, chart_w)
        full_width_help = None
    else:
        detail_lines = []
        full_width_help = render_hotkey_hint()

    lines = ['']
    for i in range(row_count):
        left = pad_vis(logo_lines[i], LOGO_W) if i < len(logo_lines) else pad_vis('', LOGO_W)
        mid = panel_lines[i] if i < len(panel_lines) else ''
        chart = chart_lines[i] if i < len(chart_lines) else ''
        gap1 = ' ' * HEADER_GAP
        gap2 = ' ' * HEADER_GAP
        line = left + gap1 + mid + gap2 + chart
        tail = max(0, W - vis_len(line))
        lines.append(line + (' ' * tail))
    # SID/AG/RUN sits under the chart column (right side, indented).
    left_indent = ' ' * (LOGO_W + HEADER_GAP + panel_w + HEADER_GAP)
    for dl in detail_lines:
        line = left_indent + dl
        tail = max(0, W - vis_len(line))
        lines.append(line + (' ' * tail))
    # Hotkey hint sits at column 0, full-width, so the long text never
    # overflows the chart column and wraps onto the status row.
    if full_width_help is not None:
        lines.append(pad_line(full_width_help))

    sub = (
        f'  {online}  '
        f'{t.fg(245)}{t.DIM}hub {hub_public}{t.R}  '
        f'{t.fg(245)}·{t.R}  {t.fg(252)}{now_str}{t.R}  '
        f'{t.fg(245)}·{t.R}  {t.fg(245)}stuck>{stuck_min}m{t.R}'
    )
    if filt:
        sub += f'  {t.fg(245)}·{t.R}  {t.fg(220)}{t.B}filter:{filt}{t.R}'
    lines.append(pad_line(sub))
    lines.append(hr('═', 39))
    return '\n'.join(lines)

def render_summary(rows):
    counts = {k: 0 for k in STATUS_STYLE}
    for r in rows:
        counts[r['status']] = counts.get(r['status'], 0) + 1
    chips = []
    for key in ('STUCK?', 'ZOMBIE', 'WORKING', 'OK', 'INACTIVE'):
        n = counts.get(key, 0)
        if n == 0 and key == 'INACTIVE':
            continue
        _, fg, bg, glyph = STATUS_STYLE[key]
        chip = f' {glyph} {key} {n} '
        if T.use and n:
            chips.append(f'{c256(fg, bg)}{t.B}{chip}{t.R}')
        elif n:
            chips.append(chip.strip())
    total = len(rows)
    title = f'{t.fg(51)}{t.B}◆ SUMMARY ◆{t.R}' if T.use else 'SUMMARY'
    body = '  '.join(chips) if chips else '(no sessions)'
    tail = f'{t.fg(245)}{t.DIM}Σ {total}{t.R}' if T.use else f'total {total}'
    inner = f' {title}  {body}  {tail} '
    if T.use:
        top = f'┌{"─" * (W - 2)}┐'
        mid = f'│{pad_line(inner, W - 2)}│'
        bot = f'└{"─" * (W - 2)}┘'
        return f'{t.fg(39)}{top}\n{mid}\n{bot}{t.R}'
    return f'+{"-" * (W - 2)}+\n|{inner}|\n+{"-" * (W - 2)}+'

def short_cmd(cmd, max_len=48):
    if not cmd:
        return '—'
    s = cmd.replace(str(Path.home()), '~')
    if len(s) <= max_len:
        return s
    return '…' + s[-(max_len - 1) :]


def compact_proc_line(procs, inner_w):
    if not procs:
        return ''
    bits = []
    for p in procs[:2]:
        cpu = p['pcpu']
        cpu_col = t.fg(46) if float(cpu) > 0.5 else t.fg(245)
        cmd = short_cmd(p['cmd'], max(16, inner_w // 3))
        if T.use:
            bits.append(
                f'{t.fg(39)}▸{t.R}'
                f' {t.fg(252)}{p["pid"]}{t.R}'
                f' {cpu_col}{cpu}%{t.R}'
                f' {t.fg(245)}{p["etimes_sec"] // 60}m{t.R}'
                f' {t.DIM}{cmd}{t.R}'
            )
        else:
            bits.append(f'->{p["pid"]} cpu{cpu}% {cmd}')
    sep = f' {t.fg(245)}│{t.R} ' if T.use else ' | '
    return sep.join(bits)


def render_compact_card_lines(r, width):
    """Low-height agent detail (1-2 lines) for width-limited column tiling."""
    st = r['status']
    _, badge_fg, bg, _glyph = STATUS_STYLE.get(st, ('?', 250, 235, '?'))
    accent = 196 if st == 'STUCK?' else (203 if st == 'ZOMBIE' else 51)
    aid = (r['agentSessionId'] or '—')[:8]
    pid = r['hostPid'] or '—'
    think = 'YES' if r['thinking'] else 'no'
    if r['thinking'] and T.use and st == 'WORKING':
        dots = '.' * (int(time.time()) % 4)
        think = f'YES{dots:<3}'
    think_col = f'{t.fg(220)}{t.B}' if r['thinking'] and T.use else ''
    think_rst = t.R if r['thinking'] and T.use else ''

    badge = status_badge(st, blink=(st == 'STUCK?'))
    model_vis = format_model_cell(r['modelTier'], r['modelLabel'])
    meta_plain = f'SID {r["sid8"]} AG {aid} {r["flavor"]} pid {pid}'
    meta_vis = len(meta_plain) + 28
    proj_w = max(8, width - meta_vis - 4)
    proj = truncate_vis(
        f'{t.fg(accent)}{t.B}{r["project"]}{t.R}' if T.use else r['project'],
        proj_w,
    )

    if T.use:
        meta = (
            f' {t.fg(245)}SID{t.R} {t.fg(87)}{r["sid8"]}{t.R}'
            f' {t.fg(245)}AG{t.R} {t.fg(213)}{aid}{t.R}'
            f' {flavor_badge(r["flavor"])}'
            f' {t.fg(245)}pid{t.R} {t.fg(252)}{pid}{t.R}'
            f' {model_vis}'
        )
    else:
        meta = f' SID {r["sid8"]} AG {aid} {r["flavor"]} pid {pid} {r["modelLabel"]}'

    note = r['note']
    if st in ('STUCK?', 'ZOMBIE') and T.use:
        note = f'{t.fg(203)}{note}{t.R}'
    elif T.use:
        note = f'{t.fg(245)}{note}{t.R}'

    think_part = (
        f' {t.fg(245)}THINK{t.R} {think_col}{think}{think_rst}  {note}'
        if T.use
        else f' THINK {think}  {r["note"]}'
    )

    rail = f'{t.fg(accent)}▌{t.R} ' if T.use else '  '
    line1 = pad_vis(f'{rail}{badge} {proj}{meta}{think_part}', width)
    lines = [line1]
    proc_body = compact_proc_line(r['procs'], max(12, width - 4))
    if proc_body:
        lines.append(pad_vis(f'{rail}{proc_body}', width))
    return lines


def render_attention_card(r, width=None):
    if os.environ.get('HAPI_HEALTH_LEGACY_CARDS') == '1':
        return render_card(r)
    w = width if width is not None else W
    return '\n'.join(render_compact_card_lines(r, w))


def _think_age(r):
    ta = r.get('thinkingAt')
    if not ta:
        return ''
    sec = max(0, int(time.time() - ta / 1000))
    if sec < 60:
        return f'{sec}s'
    if sec < 3600:
        return f'{sec // 60}m'
    return f'{sec // 3600}h{(sec % 3600) // 60}m'


def _think_cell_text(r):
    if r['status'] == 'WORKING' and r['thinking']:
        age = _think_age(r) or '?'
        return f'YES {age}'
    if r['status'] == 'STUCK?' and r['thinking']:
        return f'STK {_think_age(r) or "?"}'
    if r['status'] == 'ZOMBIE':
        return '!!!'
    return '—'


def _top_cpu(r):
    if not r['procs']:
        return None
    try:
        return max(float(p['pcpu']) for p in r['procs'])
    except (TypeError, ValueError):
        return None


def _top_mem(r):
    if not r['procs']:
        return None
    try:
        return max(float(p.get('pmem', 0)) for p in r['procs'])
    except (TypeError, ValueError):
        return None


def _status_glyph(st):
    g_map = {
        'STUCK?':   ('▲', 196, True),
        'ZOMBIE':   ('☠', 199, False),
        'WORKING':  ('◆', 51,  False),
        'OK':       ('●', 46,  False),
        'INACTIVE': ('○', 245, False),
    }
    g, col, blink = g_map.get(st, ('?', 245, False))
    if not T.use:
        return g
    if blink:
        return f'{t.BL}{t.fg(col)}{t.B}{g}{t.R}'
    return f'{t.fg(col)}{t.B}{g}{t.R}'


def render_table_header():
    # Each header label is positioned to match where the cell's content
    # actually lands. Cells that lead with a space (status ` ◆ `, type
    # ` CURSOR `) get their label leading with a space too.
    cols = [
        ('',       W_GUTTER),       # cursor gutter (empty)
        (' S',     W_STATUS),       # status glyph at cell pos 1
        (' TYPE',  W_TYPE),         # flavor badge at cell pos 1
        ('PROJ',   W_PROJ_T),
        ('MODL',   W_MODEL_T),
        ('THINK',  W_THINK_T),
        ('CPU',    W_CPU_T),
        ('RAM',    W_RAM_T),
    ]
    body = ''.join(label.ljust(w) for label, w in cols)
    body += 'NOTE'
    if not T.use:
        return body
    return f'{t.fg(245)}{t.DIM}{body}{t.R}'


def _proj_trunc(name, width):
    if len(name) <= width:
        return name + ' ' * (width - len(name))
    return name[: max(0, width - 1)] + '…'


def render_table_row(r, selected=False):
    st = r['status']
    is_active = st != 'OK'
    glyph = _status_glyph(st)
    sid_key = r['sid']

    # Gutter: 2 chars (▶ + space, or 2 spaces)
    if selected:
        gutter = f'{t.fg(220)}{t.B}▶{t.R} ' if T.use else '> '
    else:
        gutter = '  '

    # Status: 3 chars (space, glyph, space)
    status_cell = f' {glyph} '

    # Type / flavor badge: 8 chars exactly (' CURSOR ' / ' CLAUDE ' / ' CODEX  ')
    flavor_inner = f' {r["flavor"].upper():<6} '  # 1 + 6 + 1 = 8
    if T.use:
        fg, bg = FLAVOR_STYLE.get(r['flavor'], (252, 238))
        type_cell = f'{c256(fg, bg)}{t.B}{flavor_inner}{t.R}'
    else:
        type_cell = flavor_inner

    # Project: 10 chars truncated with ellipsis + 1 space = 11
    proj_text = _proj_trunc(r['project'], W_PROJ_T - 1)
    proj_styler = None
    if T.use:
        if st in ('STUCK?', 'ZOMBIE'):
            proj_styler = lambda s: f'{t.fg(203)}{t.B}{s}{t.R}'
        elif st == 'WORKING':
            proj_styler = lambda s: f'{t.fg(51)}{t.B}{s}{t.R}'
        else:
            proj_styler = lambda s: f'{t.fg(252)}{s}{t.R}'
    proj_cell = (proj_styler(proj_text) if proj_styler else proj_text) + ' '

    abbrev = model_abbrev(r['modelLabel'], W_MODEL_T - 1)
    prefix = {'prem': '$', 'eco': '·', 'unk': '?'}.get(r['modelTier'], '?')
    mvis_full = f'{prefix}{abbrev}'[: W_MODEL_T - 1]
    model_cell = mk_cell(mvis_full, W_MODEL_T - 1, lambda s: style_model(s, r['modelTier'])) + ' '

    think_txt = _think_cell_text(r)
    if T.use:
        if st == 'WORKING' and r['thinking']:
            think_styler = lambda s: f'{t.fg(220)}{t.B}{s}{t.R}'
        elif st in ('STUCK?', 'ZOMBIE'):
            think_styler = lambda s: f'{t.fg(196)}{t.B}{s}{t.R}'
        else:
            think_styler = lambda s: f'{t.DIM}{s}{t.R}'
    else:
        think_styler = None
    think_cell = mk_cell(think_txt, W_THINK_T - 1, think_styler) + ' '

    cpu = _top_cpu(r)
    cpu_txt = '—' if cpu is None else f'{cpu:.1f}%'
    if T.use:
        cpu_styler = (lambda s: f'{t.fg(46)}{s}{t.R}') if (cpu is not None and cpu > 0.5) else (lambda s: f'{t.DIM}{s}{t.R}')
    else:
        cpu_styler = None
    cpu_cell = mk_cell(cpu_txt, W_CPU_T - 1, cpu_styler) + ' '

    mem = _top_mem(r)
    mem_txt = '—' if mem is None else f'{mem:.1f}%'
    if T.use:
        mem_styler = (lambda s: f'{t.fg(141)}{s}{t.R}') if (mem is not None and mem > 1.0) else (lambda s: f'{t.DIM}{s}{t.R}')
    else:
        mem_styler = None
    mem_cell = mk_cell(mem_txt, W_RAM_T - 1, mem_styler) + ' '

    used = W_GUTTER + W_STATUS + W_TYPE + W_PROJ_T + W_MODEL_T + W_THINK_T + W_CPU_T + W_RAM_T
    note_w = max(12, W - used)
    if is_active:
        if r['procs']:
            note_src = r['procs'][0]['cmd'].replace(str(Path.home()), '~').strip()
        else:
            note_src = r['note'] or ''
    else:
        # Idle: show working directory so the operator can tell which clone /
        # worktree this session is parked on. Project col is truncated to 10,
        # NOTE has the full path.
        note_src = (r['path'] or '').replace(str(Path.home()), '~') if r['path'] else ''
    note_text = marquee(note_src, note_w, sid_key + ':note') if note_src else ' ' * note_w
    if T.use:
        if st in ('STUCK?', 'ZOMBIE'):
            note_cell = f'{t.fg(203)}{note_text}{t.R}'
        else:
            note_cell = f'{t.DIM}{note_text}{t.R}'
    else:
        note_cell = note_text

    line = f'{gutter}{status_cell}{type_cell}{proj_cell}{model_cell}{think_cell}{cpu_cell}{mem_cell}{note_cell}'
    if selected and T.use:
        bg_open = t.bg(236)
        # Pad to W so the bg colors the full row, not just the text.
        plain_w = vis_len(line)
        if plain_w < W:
            line += ' ' * (W - plain_w)
        # Inner cells reset with \033[0m which kills our bg — re-establish it
        # after each reset so the highlight survives across cells.
        inner = line.replace('\033[0m', f'\033[0m{bg_open}')
        line = f'{bg_open}{inner}\033[0m'
    return line


def render_agent_table(alert_rows, ok_rows, other_rows, cursor_sid=None):
    """Unified one-row-per-agent table, sorted by status priority."""
    lines = []
    if alert_rows:
        hdr = f'{t.fg(220)}{t.B} ⚡ ATTENTION REQUIRED ({len(alert_rows)}) {t.R}' if T.use else f'ATTENTION REQUIRED ({len(alert_rows)})'
        lines.append('')
        lines.append(pad_line(hdr))
        lines.append(render_table_header())
        if T.use:
            lines.append(f' {t.fg(245)}{t.DIM}{"─" * (W - 2)}{t.R}')
        for r in alert_rows:
            lines.append(render_table_row(r, selected=(r['sid'] == cursor_sid)))

    # Bottom region (idle + inactive) shares one row budget so it always fits
    # the viewport. INACTIVE used to be appended unconditionally, which blew
    # past terminal height and made the next emit() cycle scroll the header
    # off-screen (visible as a 1Hz flicker on the watch tick). See #8.
    total_budget = idle_display_budget(len(alert_rows))
    if other_rows:
        # Reserve chrome for the INACTIVE section: blank + header + rule + "+N below"
        # indicator (-4 in total). Missing the indicator line is what made the frame
        # exceed term_h by one and lose the trailing Σ hint to truncation.
        total_budget = max(4, total_budget - 4)
    if ok_rows and other_rows:
        # Split: at least 3 rows for each section, otherwise proportional to
        # row counts so a giant inactive list does not starve idle.
        denom = max(1, len(ok_rows) + len(other_rows))
        prop = max(3, min(len(ok_rows), (total_budget * len(ok_rows)) // denom))
        ok_budget = min(len(ok_rows), max(3, prop))
        inactive_budget = max(3, total_budget - ok_budget)
        # If one side has fewer rows than its share, donate the slack.
        if inactive_budget > len(other_rows):
            ok_budget = min(len(ok_rows), ok_budget + (inactive_budget - len(other_rows)))
            inactive_budget = len(other_rows)
        if ok_budget > len(ok_rows):
            inactive_budget = min(len(other_rows), inactive_budget + (ok_budget - len(ok_rows)))
            ok_budget = len(ok_rows)
    else:
        ok_budget = total_budget if ok_rows else 0
        inactive_budget = total_budget if other_rows and not ok_rows else 0

    if ok_rows:
        hdr = f'{t.fg(46)}{t.B} ✓ IDLE & READY ({len(ok_rows)}) {t.R}' if T.use else f'IDLE & READY ({len(ok_rows)})'
        lines.append('')
        lines.append(pad_line(hdr))
        if not alert_rows:
            lines.append(render_table_header())
        if T.use:
            lines.append(f' {t.fg(245)}{t.DIM}{"─" * (W - 2)}{t.R}')
        max_rows = min(len(ok_rows), ok_budget)
        start = 0
        if cursor_sid:
            for i, r in enumerate(ok_rows):
                if r['sid'] == cursor_sid:
                    if i >= max_rows:
                        start = i - max_rows + 1
                    break
        window = ok_rows[start:start + max_rows]
        if start > 0:
            msg = f'… +{start} idle above'
            lines.append(pad_line(f' {t.fg(245)}{t.DIM}{msg}{t.R}' if T.use else f'  {msg}'))
        for r in window:
            lines.append(render_table_row(r, selected=(r['sid'] == cursor_sid)))
        hidden = len(ok_rows) - (start + len(window))
        if hidden > 0:
            msg = f'… +{hidden} idle below (HAPI_HEALTH_IDLE_MAX to raise cap)'
            lines.append(pad_line(f' {t.fg(245)}{t.DIM}{msg}{t.R}' if T.use else f'  {msg}'))

    if other_rows:
        hdr = f'{t.fg(245)}{t.DIM} ○ INACTIVE ({len(other_rows)}){t.R}' if T.use else f'INACTIVE ({len(other_rows)})'
        lines.append('')
        lines.append(pad_line(hdr))
        if not alert_rows and not ok_rows:
            lines.append(render_table_header())
        if T.use:
            lines.append(f' {t.fg(245)}{t.DIM}{"─" * (W - 2)}{t.R}')
        max_rows = min(len(other_rows), inactive_budget)
        start = 0
        if cursor_sid:
            for i, r in enumerate(other_rows):
                if r['sid'] == cursor_sid:
                    if i >= max_rows:
                        start = i - max_rows + 1
                    break
        window = other_rows[start:start + max_rows]
        if start > 0:
            msg = f'… +{start} inactive above'
            lines.append(pad_line(f' {t.fg(245)}{t.DIM}{msg}{t.R}' if T.use else f'  {msg}'))
        for r in window:
            lines.append(render_table_row(r, selected=(r['sid'] == cursor_sid)))
        hidden = len(other_rows) - (start + len(window))
        if hidden > 0:
            msg = f'… +{hidden} inactive below'
            lines.append(pad_line(f' {t.fg(245)}{t.DIM}{msg}{t.R}' if T.use else f'  {msg}'))

    return lines


def render_hotkey_hint():
    """Full-width hotkey hint rendered at column 0 (not under the chart).

    The hint string is ~67 chars wide - too long to share the chart column
    with the panels above it. Lives on its own row at the left edge so it
    never wraps onto the status bar.
    """
    toggle_word = 'hide' if show_inactive else 'show'
    if not T.use:
        return f' j/k ↑↓ select · TAB alert · g/G top/bot · i {toggle_word} inactive · q quit'
    return (
        f' {t.fg(87)}j/k{t.R} {t.fg(87)}↑↓{t.R}{t.fg(245)}{t.DIM} select{t.R} '
        f'{t.fg(245)}{t.DIM}·{t.R} {t.fg(213)}TAB{t.R}{t.fg(245)}{t.DIM} alert{t.R} '
        f'{t.fg(245)}{t.DIM}·{t.R} {t.fg(87)}g/G{t.R}{t.fg(245)}{t.DIM} top/bot{t.R} '
        f'{t.fg(245)}{t.DIM}·{t.R} {t.fg(87)}i{t.R}{t.fg(245)}{t.DIM} {toggle_word} inactive{t.R} '
        f'{t.fg(245)}{t.DIM}·{t.R} {t.fg(196)}q{t.R}{t.fg(245)}{t.DIM} quit{t.R}'
    )


def render_detail_below_chart(selected_row, chart_w):
    """Single-line readout that fits under the chart column.

    Project + flavor are redundant with the main table row (we render the
    selected row highlighted there), so we only surface the three IDs:
    SID, AG, RUN. Caller is responsible for checking selected_row is not
    None before calling; the hotkey hint lives in render_hotkey_hint().
    """
    def fit(text):
        plain = ANSI_RE.sub('', text)
        if len(plain) >= chart_w:
            return text if T.use else text[:chart_w]
        return text + ' ' * (chart_w - len(plain))

    r = selected_row
    aid = (r['agentSessionId'] or '—')[:8]
    pid = str(r['hostPid']) if r['hostPid'] else '—'
    if not T.use:
        return [fit(f' SID {r["sid8"]}  AG {aid}  RUN {pid}')]
    return [fit(
        f' {t.fg(245)}{t.DIM}SID{t.R} {t.fg(87)}{r["sid8"]}{t.R}'
        f'  {t.fg(245)}{t.DIM}AG{t.R} {t.fg(213)}{aid}{t.R}'
        f'  {t.fg(245)}{t.DIM}RUN{t.R} {t.fg(252)}{pid}{t.R}'
    )]


def render_attention_section(alert_rows):
    """Tile WORKING/STUCK/ZOMBIE cards side-by-side when width allows."""
    if not alert_rows:
        return []
    hdr = f'{t.fg(220)}{t.B} ⚡ ATTENTION REQUIRED {t.R}' if T.use else 'ATTENTION REQUIRED'
    lines = ['', pad_line(hdr)]
    if os.environ.get('HAPI_HEALTH_LEGACY_CARDS') == '1':
        for r in alert_rows:
            lines.append(render_card(r))
        return lines

    min_col = max(32, int(os.environ.get('HAPI_HEALTH_TILE_MIN', '44') or 44))
    n = len(alert_rows)
    if n == 1:
        col_w = min(W, max(min_col, 68))
        ncol = 1
    else:
        ncol = min(n, max(1, W // min_col))
        col_w = max(min_col, W // ncol)

    card_lines = [render_compact_card_lines(r, col_w) for r in alert_rows]
    gap = '  ' if T.use else '  '
    for i in range(0, len(card_lines), ncol):
        batch = card_lines[i : i + ncol]
        row_h = max(len(c) for c in batch)
        for row_i in range(row_h):
            parts = []
            for card in batch:
                ln = card[row_i] if row_i < len(card) else ''
                parts.append(pad_vis(ln, col_w))
            lines.append(gap.join(parts))
    return lines


def attention_body_lines(alert_count):
    if alert_count <= 0:
        return 0
    if os.environ.get('HAPI_HEALTH_LEGACY_CARDS') == '1':
        return alert_count * 5
    # Unified table: one row per alert + 1 section header + 1 column header + 1 rule
    return alert_count + 3


def idle_display_budget(alert_count, header_lines=14):
    """How many idle table rows fit without burying header/chart."""
    env_cap = os.environ.get('HAPI_HEALTH_IDLE_MAX', '').strip()
    if env_cap.isdigit():
        return max(0, int(env_cap))
    term_h = shutil.get_terminal_size((40, 24)).lines
    alert_lines = attention_body_lines(alert_count)
    idle_chrome = 4  # section header + column header + rule + blank
    footer = 4       # legend + hint + blank + safety
    return max(2, term_h - header_lines - alert_lines - idle_chrome - footer)


def render_ok_section(ok_rows, budget):
    if not ok_rows:
        return []
    hdr = f'{t.fg(46)}{t.B} ✓ IDLE & READY ({len(ok_rows)}) {t.R}' if T.use else f'IDLE & READY ({len(ok_rows)})'
    lines = ['', pad_line(hdr), render_ok_header()]
    if T.use:
        lines.append(f' {t.fg(245)}{t.DIM}{"─" * (W - 2)}{t.R}')
    max_rows = min(len(ok_rows), budget)
    for r in ok_rows[:max_rows]:
        lines.append(render_ok_row(r))
    hidden = len(ok_rows) - max_rows
    if hidden > 0:
        msg = f'… +{hidden} idle hidden (terminal height; set HAPI_HEALTH_IDLE_MAX)'
        lines.append(pad_line(f' {t.fg(245)}{t.DIM}{msg}{t.R}' if T.use else f'  {msg}'))
    return lines


def render_card(r):
    st = r['status']
    _, badge_fg, bg, glyph = STATUS_STYLE.get(st, ('?', 250, 235, '?'))
    accent = bg
    aid = (r['agentSessionId'] or '—')[:8]
    think = 'YES' if r['thinking'] else 'no'
    think_col = t.fg(220) + t.B if r['thinking'] and T.use else ''
    think_rst = t.R if r['thinking'] and T.use else ''
    if r['thinking'] and T.use and st == 'WORKING':
        dots = '.' * (int(time.time()) % 4)
        think = f'YES{dots:<3}'

    title = f'{status_badge(st, blink=(st == "STUCK?"))}  {t.fg(accent)}{t.B}{r["project"]}{t.R}' if T.use else f'{st}  {r["project"]}'
    meta = (
        f' SID {t.fg(87)}{r["sid8"]}{t.R}'
        f'  AGENT {t.fg(213)}{aid}{t.R}'
        f'  {flavor_badge(r["flavor"])}'
        f'  PID {t.fg(252)}{r["hostPid"] or "—"}{t.R}'
        f'  MODEL {format_model_cell(r["modelTier"], r["modelLabel"])}'
    ) if T.use else f' SID {r["sid8"]}  AGENT {aid}  {r["flavor"]}  PID {r["hostPid"] or "—"}  MODEL {r["modelLabel"]}'

    note_col = t.fg(203) if st in ('STUCK?', 'ZOMBIE') and T.use else (t.fg(245) if T.use else '')
    note = f'{note_col}{r["note"]}{t.R}' if T.use else r['note']
    think_line = f' THINK {think_col}{think}{think_rst}   {note}'

    parts = []
    parts.append('')
    border = '━' if T.use else '-'
    parts.append(f'{t.fg(accent)}┏{border * W}┓{t.R}' if T.use else '+' + border * W + '+')
    inner_w = W - 2
    s = lambda text: f'{t.fg(accent)}┃{t.R} {pad_line(text, inner_w)} {t.fg(accent)}┃{t.R}' if T.use else f'| {text} |'
    parts.append(s(title))
    parts.append(s(meta))
    parts.append(s(think_line))
    if r['thinking'] and st == 'WORKING' and T.use:
        scan = int(time.time()) % inner_w
        bar = ['░'] * inner_w
        for i in range(8):
            pos = (scan + i) % inner_w
            bar[pos] = '▓'
        parts.append(s(f'{t.fg(51)}{"".join(bar)}{t.R}'))
    for p in r['procs']:
        cpu = p['pcpu']
        cpu_col = t.fg(46) if float(cpu) > 0.5 else t.fg(245)
        proc = (
            f' {t.fg(39)}▸{t.R} pid {t.fg(252)}{p["pid"]}{t.R}'
            f' {t.fg(245)}{p["stat"]}{t.R}'
            f' {cpu_col}cpu{cpu}{t.R}%'
            f' {t.fg(245)}{p["etimes_sec"]//60}m{t.R}'
            f' {t.DIM}{p["cmd"][: inner_w - 28]}{t.R}'
        ) if T.use else f' -> pid {p["pid"]} {p["stat"]} cpu{cpu}% {p["cmd"][:60]}'
        parts.append(s(proc))
    parts.append(f'{t.fg(accent)}┗{border * W}┛{t.R}' if T.use else '+' + border * W + '+')
    return '\n'.join(parts)

def render_backups_panel():
    lines = [ln.strip() for ln in ps_lines() if 'borg' in ln.lower() and 'grep' not in ln.lower()]
    create = [ln for ln in lines if ' borg create ' in f' {ln.lower()} ']
    parts = ['', hr('─', 240)]
    title = f'{t.fg(141)}{t.B} BACKUP CROSS-CHECK {t.R}' if T.use else 'BACKUP CROSS-CHECK'
    parts.append(pad_line(f' {title}'))
    if create:
        for ln in create[:3]:
            parts.append(pad_line(f' {t.fg(196)}{t.B}▲ BORG CREATE{t.R}  {t.fg(252)}{ln[:W-20]}{t.R}' if T.use else f'BORG CREATE  {ln[:80]}'))
    elif lines:
        parts.append(pad_line(f' {t.fg(245)}borg idle (list/prune only, no create running){t.R}' if T.use else 'borg idle'))
    else:
        parts.append(pad_line(f' {t.fg(46)}● no borg process{t.R}' if T.use else 'no borg'))
    try:
        svc = subprocess.run(['systemctl', 'is-active', 'backup-system-full.service'],
                             capture_output=True, text=True, timeout=5)
        state = (svc.stdout or svc.stderr or '?').strip()
        col = t.fg(46) if state == 'active' else (t.fg(196) if state == 'failed' else t.fg(220))
        parts.append(pad_line(f' {col}system backup service: {state}{t.R}' if T.use else f'system backup: {state}'))
    except Exception as e:
        parts.append(pad_line(f' system backup: check failed ({e})'))
    log = os.path.expanduser('~/logs/backup_jellybot_subtitles.log')
    if os.path.isfile(log):
        try:
            tail = subprocess.check_output(['tail', '-1', log], text=True).strip()
            parts.append(pad_line(f' {t.fg(245)}{t.DIM}{tail[:W-4]}{t.R}' if T.use else tail[:80]))
        except Exception:
            pass
    parts.append(hr('─', 240))
    return '\n'.join(parts)



def get_optional(url, auth=True):
    try:
        return get(url, auth=auth)
    except Exception:
        return None

def sh_cmd(*args):
    try:
        return subprocess.check_output(list(args), text=True, stderr=subprocess.DEVNULL).strip()
    except Exception:
        return None

def fmt_ts(path_or_mtime):
    if path_or_mtime is None:
        return '—'
    if isinstance(path_or_mtime, (int, float)):
        dt = datetime.fromtimestamp(path_or_mtime)
    else:
        p = Path(path_or_mtime)
        if not p.exists():
            return '—'
        dt = datetime.fromtimestamp(p.stat().st_mtime)
    return dt.astimezone().strftime('%m-%d %H:%M')

def systemd_unit(unit):
    out = sh_cmd('systemctl', 'show', unit, '-p', 'ActiveState,MainPID,ActiveEnterTimestamp', '--no-pager')
    info = {}
    if not out:
        return info
    for line in out.splitlines():
        if '=' in line:
            k, v = line.split('=', 1)
            info[k] = v
    return info

def read_app_version():
    p = repo / 'shared/src/buildInfo.ts'
    if not p.exists():
        return None
    m = re.search(r"APP_VERSION = '([^']+)'", p.read_text())
    return m.group(1) if m else None

def read_embedded_bundle():
    p = repo / 'hub/src/web/embeddedAssets.generated.ts'
    if not p.exists():
        return None, None
    text = p.read_text()
    m = re.search(r"assets/(index-[^.]+\.js)", text)
    return (m.group(1), p) if m else (None, p)

def read_dist_bundle():
    assets = sorted((repo / 'web/dist/assets').glob('index-*.js'))
    if not assets:
        return None, None
    return assets[-1].name, assets[-1]

def collect_build_info():
    health = get_optional(f'{hub}/health', auth=False) or {}
    git_commit = sh_cmd('git', '-C', str(repo), 'rev-parse', '--short', 'HEAD')
    git_branch = sh_cmd('git', '-C', str(repo), 'branch', '--show-current')
    git_dirty = bool(sh_cmd('git', '-C', str(repo), 'status', '--porcelain'))
    cli_raw = sh_cmd('hapi', '--version')
    cli_version = cli_raw.replace('hapi version:', '').strip() if cli_raw else None
    bun_version = sh_cmd('bun', '--version')
    hub_unit = systemd_unit('hapi-hub.service')
    runner_unit = systemd_unit('hapi-runner.service')
    dist_bundle, dist_path = read_dist_bundle()
    embedded_bundle, embedded_path = read_embedded_bundle()
    bundles_match = bool(dist_bundle and embedded_bundle and dist_bundle == embedded_bundle)
    embedded_stale = False
    if dist_path and embedded_path and dist_path.exists() and embedded_path.exists():
        embedded_stale = dist_path.stat().st_mtime > embedded_path.stat().st_mtime + 1
    machines = []
    for m in (get_optional(f'{hub}/api/machines') or {}).get('machines', []):
        meta = m.get('metadata') or {}
        runner = m.get('runnerState') or {}
        machines.append({
            'host': meta.get('host'),
            'cliVersion': meta.get('happyCliVersion'),
            'libDir': meta.get('happyLibDir'),
            'runnerStatus': runner.get('status'),
            'runnerPid': runner.get('pid'),
            'runnerPort': runner.get('httpPort'),
        })
    return {
        'appVersionSource': read_app_version(),
        'protocolVersion': health.get('protocolVersion'),
        'gitCommit': git_commit,
        'gitBranch': git_branch,
        'gitDirty': git_dirty,
        'cliVersion': cli_version,
        'bunVersion': bun_version,
        'hubService': hub_unit,
        'runnerService': runner_unit,
        'web': {
            'distBundle': dist_bundle,
            'distBuiltAt': fmt_ts(dist_path) if dist_path else None,
            'embeddedBundle': embedded_bundle,
            'embeddedGeneratedAt': fmt_ts(embedded_path) if embedded_path else None,
            'bundlesMatch': bundles_match,
            'embeddedStale': embedded_stale,
        },
        'machines': machines,
    }

def get(url, auth=True):
    """Hub API call. Raises HubUnavailable for any failure mode; never crashes
    on a transient connection blip. Auto-retries once after refreshing the JWT
    if the hub returns 401."""
    def _attempt():
        headers = {}
        if auth:
            headers['Authorization'] = f'Bearer {_get_token()}'
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.load(r)
    try:
        return _attempt()
    except urllib.error.HTTPError as e:
        if e.code == 401 and auth:
            _invalidate_token()
            try:
                return _attempt()
            except Exception as e2:
                raise HubUnavailable(f'auth refresh failed for {url}: {e2}') from e2
        raise HubUnavailable(f'HTTP {e.code} from {url}') from e
    except urllib.error.URLError as e:
        raise HubUnavailable(f'cannot reach {url}: {e.reason}') from e
    except (socket.timeout, TimeoutError) as e:
        raise HubUnavailable(f'timeout fetching {url}: {e}') from e
    except json.JSONDecodeError as e:
        raise HubUnavailable(f'invalid JSON from {url}: {e}') from e
    except OSError as e:
        raise HubUnavailable(f'network error on {url}: {e}') from e

_PS_CACHE = {'lines': None}

def ps_lines():
    if _PS_CACHE['lines'] is not None:
        return _PS_CACHE['lines']
    try:
        out = subprocess.check_output(['ps', '-eo', 'pid,etimes,stat,pcpu,pmem,args'], text=True, errors='replace')
        _PS_CACHE['lines'] = out.splitlines()[1:]
    except Exception:
        _PS_CACHE['lines'] = []
    return _PS_CACHE['lines']

def find_pids(needles):
    hits = []
    for line in ps_lines():
        low = line.lower()
        if any(n and n.lower() in low for n in needles if n):
            parts = line.split(None, 5)
            if len(parts) >= 6:
                hits.append({
                    'pid': int(parts[0]),
                    'etimes_sec': int(parts[1]),
                    'stat': parts[2],
                    'pcpu': parts[3],
                    'pmem': parts[4],
                    'cmd': parts[5][:160],
                })
    return hits

def fmt_age_ms(ms):
    if not ms:
        return '—'
    sec = max(0, int(time.time() - ms/1000))
    if sec < 60:
        return f'{sec}s'
    if sec < 3600:
        return f'{sec//60}m'
    return f'{sec//3600}h{sec%3600//60}m'

def short_project(path):
    """Drop ~/coding/ prefix — most sessions live there."""
    from pathlib import Path
    if not path or path == '?':
        return '?'
    p = Path(path).expanduser()
    coding = Path.home() / 'coding'
    try:
        rel = p.relative_to(coding)
        s = p.name if rel == Path('.') else str(rel)
    except ValueError:
        try:
            rel = p.relative_to(Path.home())
            s = f'~/{rel}'
        except ValueError:
            s = str(p)
    if len(s) > 28:
        s = '…' + s[-27:]
    return s

def model_from_proc(procs):
    for p in procs:
        parts = p.get('cmd', '').split()
        for i, arg in enumerate(parts):
            if arg == '--model' and i + 1 < len(parts):
                return parts[i + 1]
    return None

def extract_session_model(detail, procs):
    m = detail.get('model') or (detail.get('metadata') or {}).get('model')
    if isinstance(m, str) and m.strip():
        return m.strip()
    for msg in reversed(detail.get('messages') or []):
        if not isinstance(msg, dict):
            continue
        if isinstance(msg.get('model'), str) and msg['model'].strip():
            return msg['model'].strip()
        for block in (msg.get('blocks') or []):
            if isinstance(block, dict) and isinstance(block.get('model'), str) and block['model'].strip():
                return block['model'].strip()
    return model_from_proc(procs)

def model_tier(flavor, model):
    """Best-effort premium vs economy. Cursor often unknown — HAPI ignores model sync."""
    if flavor == 'claude':
        return 'prem', (model or 'claude')
    if not model:
        return ('unk', 'auto') if flavor == 'cursor' else ('unk', '—')
    ml = model.lower()
    if ml == 'auto':
        return 'unk', 'auto'
    if '-low' in ml or ml.endswith('-low-fast') or ml == 'composer-2-fast' or (ml.startswith('composer') and '-fast' in ml):
        return 'eco', model
    return 'prem', model

def format_model_cell(tier, label):
    """Legacy helper for cards; idle rows use mk_cell + model_visible."""
    vis = model_visible(tier, label)
    if not T.use:
        return vis
    return style_model(vis.ljust(W_MODEL), tier)

def render_ok_row(r):
    dot = f'{t.fg(46)}●{t.R}' if T.use else '·'
    fl = flavor_badge(r['flavor'])
    mvis = model_visible(r['modelTier'], r['modelLabel'])
    pid = f"pid {r['hostPid'] or '—'}"
    if T.use:
        return (
            f' {dot} {fl} '
            f'{mk_cell(r["project"], W_PROJ, lambda s: f"{t.fg(252)}{s}{t.R}")}'
            f'{mk_cell(mvis, W_MODEL, lambda s: style_model(s, r["modelTier"]))}'
            f'{mk_cell(r["sid8"], W_SID, lambda s: f"{t.fg(87)}{s}{t.R}")}'
            f'{mk_cell(pid, W_PID, lambda s: f"{t.fg(245)}{s}{t.R}")}'
        )
    return (
        f'OK  {r["flavor"]}  '
        f'{mk_cell(r["project"], W_PROJ)}'
        f'{mk_cell(mvis, W_MODEL)}'
        f'{mk_cell(r["sid8"], W_SID)}'
        f'{mk_cell(pid, W_PID)}'
    )

def classify(active, thinking, thinking_at, updated_at, host_pid, agent_id, lifecycle):
    needles = [str(host_pid) if host_pid else '', agent_id or '']
    procs = find_pids(needles)
    runner = [p for p in procs if 'hapi' in p['cmd'].lower() and (not agent_id or agent_id[:8] in p['cmd'])]
    agent = [p for p in procs if 'agent' in p['cmd'].lower() or 'claude' in p['cmd'].lower() or 'codex' in p['cmd'].lower()]
    if agent_id:
        agent = [p for p in procs if agent_id[:8] in p['cmd']] or agent

    alive = bool(runner or agent or (host_pid and any(p['pid'] == int(host_pid) for p in procs if host_pid)))

    if not active:
        return 'INACTIVE', 'hub inactive', procs

    if not alive:
        return 'ZOMBIE', 'hub active but no runner/agent PID', procs

    if thinking:
        think_age = fmt_age_ms(thinking_at)
        think_sec = max(0, int(time.time() - (thinking_at or 0)/1000)) if thinking_at else 0
        upd_sec = max(0, int(time.time() - (updated_at or 0)/1000)) if updated_at else 0
        if think_sec >= stuck_min * 60:
            return 'STUCK?', f'thinking {think_age}; last update {fmt_age_ms(updated_at)} ago', procs
        if upd_sec >= stuck_min * 60 and think_sec >= 5 * 60:
            return 'STUCK?', f'thinking {think_age}, no message update {fmt_age_ms(updated_at)}', procs
        return 'WORKING', f'thinking {think_age}', procs

    return 'OK', 'idle, ready for input', procs

from concurrent.futures import ThreadPoolExecutor


def _fetch_detail(item):
    try:
        return item, get(f'{hub}/api/sessions/{item["id"]}').get('session', {})
    except Exception:
        return item, {}


_STATUS_ORDER = {'STUCK?': 0, 'ZOMBIE': 1, 'WORKING': 2, 'OK': 3, 'INACTIVE': 4}


def gather_rows():
    """Build the (sorted) row list for one tick. Re-callable from the watch loop."""
    _PS_CACHE['lines'] = None  # invalidate ps cache for fresh CPU/RAM data
    sessions_raw = get(f'{hub}/api/sessions').get('sessions', [])
    if filt:
        sessions_raw = [s for s in sessions_raw if filt in json.dumps(s).lower()]
    if sessions_raw:
        with ThreadPoolExecutor(max_workers=min(16, len(sessions_raw))) as _ex:
            session_pairs = list(_ex.map(_fetch_detail, sessions_raw))
    else:
        session_pairs = []
    out_rows = []
    for item, detail in session_pairs:
        sid = item['id']
        meta = detail.get('metadata') or item.get('metadata') or {}
        host_pid = meta.get('hostPid')
        agent_id = meta.get('cursorSessionId') or meta.get('claudeSessionId') or meta.get('codexSessionId') or meta.get('agentSessionId')
        thinking_at = detail.get('thinkingAt') or item.get('thinkingAt') or 0
        updated_at = detail.get('updatedAt') or item.get('updatedAt') or 0
        recency_at = max(int(thinking_at or 0), int(updated_at or 0))
        status, note, procs = classify(
            bool(item.get('active')),
            bool(item.get('thinking')),
            thinking_at,
            updated_at,
            host_pid,
            agent_id,
            meta.get('lifecycleState'),
        )
        # INACTIVE always retained so the total count + chart stay honest;
        # display filter happens later via the `show_inactive` toggle.
        model = extract_session_model(detail, procs)
        tier, label = model_tier(meta.get('flavor', '?'), model)
        path = meta.get('path') or '?'
        out_rows.append({
            'status': status,
            'sid': sid,
            'sid8': sid[:8],
            'flavor': meta.get('flavor', '?'),
            'path': path,
            'machineId': meta.get('machineId') or item.get('machineId'),
            'project': short_project(path),
            'thinking': item.get('thinking', False),
            'thinkingAt': thinking_at,
            'lifecycle': meta.get('lifecycleState'),
            'hostPid': host_pid,
            'agentSessionId': agent_id,
            'modelTier': tier,
            'modelLabel': label,
            'note': note,
            'procs': procs[:2],
            'pending': item.get('pendingRequestsCount', 0),
            'recencyAt': recency_at,
            'updatedAt': updated_at,
        })
    # Nothing tick-derived is allowed in the sort key — CPU/RAM/recency all
    # jitter once per second and the list would reshuffle for no reason.
    # Active rows (WORKING/STUCK?/ZOMBIE): order by thinkingAt ASC so the
    # longest-running thought floats to top (most likely candidate to go
    # STUCK). thinkingAt is set once per think cycle and stays constant
    # until the agent transitions out, so the order only changes when an
    # agent actually starts or stops thinking.
    # Idle / inactive: stable alpha by project → flavor → sid.
    def _sort_key(r):
        status_rank = _STATUS_ORDER.get(r['status'], 9)
        if r['status'] in ('WORKING', 'STUCK?', 'ZOMBIE'):
            return (status_rank, r.get('thinkingAt') or 0, r['sid'])
        return (status_rank, r['project'], r['flavor'], r['sid'])
    out_rows.sort(key=_sort_key)
    return out_rows


def render_error_frame(err, attempt, tick_sec):
    """Friendly TUI banner when the hub is unreachable. Stays on alt-screen
    so the operator can read it and the loop keeps retrying behind it."""
    msg_lines = str(err).splitlines() or ['unknown error']
    title = '⚠  HUB UNREACHABLE' if T.use else 'HUB UNREACHABLE'
    body = [
        '',
        f'  {title}',
        '',
    ]
    for ln in msg_lines:
        body.append(f'  {ln}')
    body += [
        '',
        f'  attempt {attempt} · retrying every {tick_sec:g}s',
        '',
        '  Is the hub running?',
        f'    curl -fsS {hub}/api/health',
        '    systemctl status hapi-hub  (or your service name)',
        '',
        '  press q to quit',
        '',
    ]
    out = []
    if T.use:
        bar = '═' * max(0, W - 2)
        out.append(f'{t.fg(196)}╔{bar}╗{t.R}')
        for ln in body:
            pad = max(0, W - 2 - vis_len(ln))
            cell = f'{t.fg(220)}{ln}{t.R}{" " * pad}' if 'UNREACHABLE' in ln else f'{ln}{" " * pad}'
            out.append(f'{t.fg(196)}║{t.R}{cell}{t.fg(196)}║{t.R}')
        out.append(f'{t.fg(196)}╚{bar}╝{t.R}')
    else:
        bar = '=' * max(0, W - 2)
        out.append(f'+{bar}+')
        for ln in body:
            pad = max(0, W - 2 - len(ln))
            out.append(f'|{ln}{" " * pad}|')
        out.append(f'+{bar}+')
    return '\n'.join(out)


def emit(text):
    """Print once, or redraw in-place during --watch (no flicker, no bounce).

    Flicker comes from clearing the screen then drawing. Instead we:
    1. Wrap the frame in DEC synchronized-update sequences (no half-frames on
       terminals that grok them — iTerm2, Kitty, Konsole, tmux 3.4+).
    2. Move cursor home (not clear).
    3. Pad or truncate to exactly the viewport height so the terminal NEVER
       scrolls (#12). Variable frame heights used to oscillate by 1-2 lines
       as `+N below` indicators came and went, causing the header to bounce
       on every refresh tick.
    4. Each line gets \\033[K (erase to EOL) so leftovers from the prior frame
       on the same row get wiped without a blank flash.
    """
    if watch_mode and watch_redraw:
        lines = text.split('\n')
        term_h = shutil.get_terminal_size((80, 24)).lines
        if len(lines) < term_h:
            lines.extend([''] * (term_h - len(lines)))
        elif len(lines) > term_h:
            lines = lines[:term_h]
        parts = ['\033[?2026h', '\033[H']
        for i, ln in enumerate(lines):
            parts.append(ln)
            parts.append('\033[K')
            if i < len(lines) - 1:
                parts.append('\n')
        parts.append('\033[?2026l')
        sys.stdout.write(''.join(parts))
    else:
        sys.stdout.write(text)
        if not text.endswith('\n'):
            sys.stdout.write('\n')
    sys.stdout.flush()

def build_frame(rows, cursor_sid=None):
    """Compose one complete frame. Pure function of (rows, cursor_sid, time)."""
    now_str = datetime.now().astimezone().strftime('%Y-%m-%d %H:%M:%S')
    # rows = full dataset (incl INACTIVE). visible = what the user sees right
    # now based on the toggle. Header/chart use full rows so counts/peaks are
    # honest; table + cursor only walk visible rows.
    visible = rows if show_inactive else [r for r in rows if r['status'] != 'INACTIVE']
    alert_rows = [r for r in visible if r['status'] in ('STUCK?', 'ZOMBIE', 'WORKING')]
    ok_rows = [r for r in visible if r['status'] == 'OK']
    other_rows = [r for r in visible if r['status'] not in ('STUCK?', 'ZOMBIE', 'WORKING', 'OK')]

    selected_row = next((r for r in visible if r['sid'] == cursor_sid), None) if cursor_sid else None

    out = []
    builds = collect_build_info()
    out.append(render_header(now_str, builds, rows, selected_row=selected_row))

    if os.environ.get('HAPI_HEALTH_LEGACY_CARDS') == '1':
        if alert_rows:
            out.extend(render_attention_section(alert_rows))
        if ok_rows:
            out.extend(render_ok_section(ok_rows, idle_display_budget(len(alert_rows))))
        for r in other_rows:
            out.append(render_attention_card(r, W))
    else:
        out.extend(render_agent_table(alert_rows, ok_rows, other_rows, cursor_sid=cursor_sid))

    out.append('')
    out.append(pad_line(render_legend()))
    hidden_inactive = sum(1 for r in rows if r['status'] == 'INACTIVE') if not show_inactive else 0
    out.append(pad_line(render_list_hint(len(visible), visible, hidden_inactive=hidden_inactive)))

    if show_backups:
        out.append(render_backups_panel())

    return '\n'.join(out)


def displayable_order(rows):
    """Order rows the way the table renders them — needed for cursor math.

    Honours show_inactive: hidden rows are skipped so j/k can't land on them.
    """
    visible = rows if show_inactive else [r for r in rows if r['status'] != 'INACTIVE']
    alert_rows = [r for r in visible if r['status'] in ('STUCK?', 'ZOMBIE', 'WORKING')]
    ok_rows = [r for r in visible if r['status'] == 'OK']
    other_rows = [r for r in visible if r['status'] not in ('STUCK?', 'ZOMBIE', 'WORKING', 'OK')]
    return alert_rows + ok_rows + other_rows


def _handle_key(ch, cursor_idx, ordered):
    """Return new cursor_idx, or None to quit."""
    if ch in ('q', 'Q', '\x03'):  # q, Q, Ctrl-C
        return None
    n = len(ordered)
    if n == 0:
        return cursor_idx
    if ch in ('j', '\x1bOB'):  # down arrow (xterm alt)
        return min(n - 1, max(0, cursor_idx) + 1) if cursor_idx >= 0 else 0
    if ch in ('k', '\x1bOA'):
        return max(0, cursor_idx - 1) if cursor_idx > 0 else 0
    if ch == '\t':
        # next attention row, wrapping
        alert_ix = [i for i, r in enumerate(ordered) if r['status'] in ('STUCK?', 'ZOMBIE', 'WORKING')]
        if not alert_ix:
            return cursor_idx
        next_alert = next((i for i in alert_ix if i > cursor_idx), alert_ix[0])
        return next_alert
    if ch in ('g', '\x1b[1~'):
        return 0
    if ch in ('G', '\x1b[4~'):
        return n - 1
    if ch == '\x1b':  # ESC alone (might be start of seq, handled below)
        return cursor_idx
    return cursor_idx


def watch_loop():
    """Long-running render loop with keyboard nav. Replaces bash sleep loop.

    stdin is the heredoc (not the terminal) so we read keys from /dev/tty
    directly. Falls back to no-input mode if /dev/tty isn't available.
    """
    import select, termios, tty
    try:
        kbd = open('/dev/tty', 'rb', buffering=0)
        is_tty = True
    except OSError:
        kbd = None
        is_tty = False
    fd = kbd.fileno() if is_tty else None
    old_attr = termios.tcgetattr(fd) if is_tty else None
    if is_tty:
        tty.setcbreak(fd)
    sys.stdout.write('\033[?1049h\033[?25l')  # alt screen + hide cursor
    sys.stdout.flush()

    try:
        try:
            tick = float(os.environ.get('HAPI_WATCH_SEC', '1'))
        except ValueError:
            tick = 1.0

        # Cursor sticks to the *agent* (sid), not the row index — the table
        # reorders as agents start/stop thinking. None = nothing selected.
        cursor_sid = None
        global watch_redraw
        watch_redraw = False  # first paint = full draw
        last_data_at = 0.0
        rows = []

        def resolve_idx(_ordered, _sid):
            if _sid is None:
                return -1
            for i, r in enumerate(_ordered):
                if r['sid'] == _sid:
                    return i
            return -1

        error_attempt = 0
        while True:
            now = time.time()
            need_data = (now - last_data_at) >= tick or not rows
            if need_data:
                try:
                    rows = gather_rows()
                    last_data_at = now
                    error_attempt = 0  # recovered
                except HubUnavailable as e:
                    error_attempt += 1
                    last_data_at = now
                    emit(render_error_frame(e, error_attempt, tick))
                    watch_redraw = True
                    # Sleep until next tick but still poll for 'q' so the user
                    # isn't stuck staring at the error screen.
                    deadline = now + tick
                    while time.time() < deadline:
                        if not is_tty:
                            time.sleep(min(0.2, deadline - time.time()))
                            continue
                        r, _, _ = select.select([kbd], [], [], min(0.2, max(0, deadline - time.time())))
                        if not r:
                            continue
                        ch = kbd.read(1).decode('latin-1', errors='ignore')
                        if ch in ('q', 'Q', '\x03', '\x1b'):
                            return
                    continue

            ordered = displayable_order(rows)
            cursor_idx = resolve_idx(ordered, cursor_sid)
            if cursor_sid is not None and cursor_idx == -1:
                # Selected agent vanished — clear selection.
                cursor_sid = None
            emit(build_frame(rows, cursor_sid))
            watch_redraw = True

            # Sleep with keyboard polling (re-render on every key or marquee step).
            frame_deadline = last_data_at + tick
            marquee_step = max(0.1, 1.0 / max(1, SCROLL_CHARS_PER_SEC))  # repaint at scroll rate
            next_paint = time.time() + marquee_step
            while True:
                now = time.time()
                if now >= frame_deadline:
                    break
                if now >= next_paint:
                    emit(build_frame(rows, cursor_sid))
                    next_paint = now + marquee_step
                if not is_tty:
                    time.sleep(min(frame_deadline - now, marquee_step))
                    continue
                wait = min(frame_deadline - now, next_paint - now, 0.2)
                r, _, _ = select.select([kbd], [], [], max(0, wait))
                if not r:
                    continue
                raw = kbd.read(1)
                if not raw:
                    continue
                ch = raw.decode('latin-1', errors='ignore')
                if ch in ('i', 'I'):
                    # Toggle INACTIVE visibility live. Re-derive cursor + repaint
                    # immediately so the operator sees the rows appear/disappear.
                    global show_inactive
                    show_inactive = not show_inactive
                    ordered = displayable_order(rows)
                    cursor_idx = resolve_idx(ordered, cursor_sid)
                    if cursor_sid is not None and cursor_idx == -1:
                        cursor_sid = None
                    emit(build_frame(rows, cursor_sid))
                    next_paint = time.time() + marquee_step
                    continue
                if ch == '\x1b':
                    r2, _, _ = select.select([kbd], [], [], 0.05)
                    if r2:
                        ch2 = kbd.read(1).decode('latin-1', errors='ignore')
                        if ch2 in ('[', 'O'):
                            ch3 = kbd.read(1).decode('latin-1', errors='ignore')
                            seq = '\x1b' + ch2 + ch3
                            if seq.endswith('A'):
                                new = _handle_key('\x1bOA', cursor_idx, ordered)
                            elif seq.endswith('B'):
                                new = _handle_key('\x1bOB', cursor_idx, ordered)
                            else:
                                new = _handle_key(seq, cursor_idx, ordered)
                        else:
                            new = _handle_key(ch + ch2, cursor_idx, ordered)
                    else:
                        new = None  # bare ESC = quit
                else:
                    new = _handle_key(ch, cursor_idx, ordered)
                if new is None:
                    return
                if new != cursor_idx:
                    cursor_idx = new
                    cursor_sid = ordered[cursor_idx]['sid'] if 0 <= cursor_idx < len(ordered) else None
                    emit(build_frame(rows, cursor_sid))
                    next_paint = time.time() + marquee_step
                    # also bump the cached resolved index so subsequent keys
                    # within this inner tick use the new position
                    pass
    finally:
        sys.stdout.write('\033[?25h\033[?1049l')
        sys.stdout.flush()
        if is_tty and old_attr is not None:
            termios.tcsetattr(fd, termios.TCSADRAIN, old_attr)
        if kbd is not None:
            try:
                kbd.close()
            except Exception:
                pass


def _friendly_exit(err):
    """Print a HubUnavailable in a clean operator-readable way and exit 1."""
    print(f'hapi-monitor: {err}', file=sys.stderr)
    print(f'  hub URL: {hub}', file=sys.stderr)
    print(f'  settings: {settings_path}', file=sys.stderr)
    print(f'  override with HAPI_HUB_URL / HAPI_JWT / HAPI_SETTINGS', file=sys.stderr)
    sys.exit(1)

try:
    if as_json:
        rows = gather_rows()
        builds = collect_build_info()
        emit(json.dumps({'builds': builds, 'sessions': rows}, indent=2))
        sys.exit(0)

    if watch_mode:
        watch_loop()
        sys.exit(0)

    # one-shot
    rows = gather_rows()
    emit(build_frame(rows, cursor_sid=None))
except HubUnavailable as e:
    _friendly_exit(e)
except KeyboardInterrupt:
    sys.exit(130)
except BrokenPipeError:
    # Stdout was closed (e.g. piped to `head`). Quietly bail.
    try:
        sys.stderr.close()
    except Exception:
        pass
    sys.exit(0)
PY
}

if [[ "$WATCH" -eq 1 ]]; then
  export FORCE_COLOR=1
  export HAPI_WATCH=1
  export HAPI_WATCH_SEC="$WATCH_SEC"
  export HAPI_CHART_STATE="${HAPI_CHART_STATE:-${TMPDIR:-/tmp}/hapi-monitor-chart.$$}"
  cleanup_watch() {
    rm -f "${HAPI_CHART_STATE:-}"
  }
  trap cleanup_watch EXIT INT TERM
  : >"$HAPI_CHART_STATE"
  # Python now owns alt-screen + cursor-hide and the redraw/keypoll loop.
  report
else
  report
fi
