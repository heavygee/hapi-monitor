# Anatomy of the hapi-monitor TUI

The screen is dense on purpose - one tmux pane shows everything a HAPI
operator needs to triage agents in real time. This page walks line by
line through what every glyph, color, badge, and footer fragment means.

The reference frame below is a 128x38 tmux pane during a typical hub
session with two CURSOR agents thinking, eight idle, and 68 inactive
sessions hidden behind the `i` toggle.

```
                                        ┌─────────────────────────────────────────────┐  ┌ AGENTS ─────────────────────┐
  ██╗  ██╗   █████╗   ██████╗  ██╗      │ BUILD + STATE                               │  │   ┤ ── working 3   ── peak 3│
  ██║  ██║  ██╔══██╗  ██╔══██╗ ██║      │ ──────────────────────────                  │  │  3┤─────────────────────────│
  ██║  ██║  ██║  ██║  ██║  ██║ ██║      │ app 0.19.0  p1  cli 0.18.4                  │  │   ┤                         │
  ██║  ██║  ██║  ██║  ██║  ██║ ██║      │ git driver/integration@3039d1c*             │  │   ┤                         │
  ███████║  ███████║  ██████╔╝ ██║      │ hub active:6373  run active:6836            │  │  2┤                         │
  ██╔══██║  ██╔══██║  ██╔═══╝  ██║      │ web D3OBJS52@06-02 06:58  MISMATCH          │  │  1┤                         │
  ██║  ██║  ██║  ██║  ██║      ██║      │ proxmox  running pid 6836 :40677            │  │   ┤                         │
  ██║  ██║  ██║  ██║  ██║      ██║      │ sessions 79   ◆WORKING 3 ●OK 8 ○INACTIVE 68 │  │  0┤                         │
  ╚═╝  ╚═╝  ╚═╝  ╚═╝  ╚═╝      ╚═╝      └─────────────────────────────────────────────┘  └─────────────────────────────┘
 j/k ↑↓ select · TAB alert · g/G top/bot · i hide inactive · q quit
  ◴ ONLINE  hub https://hapi.tail9944ee.ts.net  ·  2026-06-02 14:55:48  ·  stuck>20m
════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════

 ⚡ ATTENTION REQUIRED (3)
   S  TYPE   PROJ       MODL  THINK    CPU    RAM    NOTE
 ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
   ◆  CURSOR hapi       ?auto YES 2s   9.0%   0.7%   ursor --resume d9c3d739-f146-434a-83   ~/.bun/bin/bun --cwd ~/codin
   ◆  CURSOR hapi-moni… ?auto YES 2s   3.6%   1.0%   index.ts cursor --hapi-starting-mode remote --   ~/.bun/bin/bun --c
   ◆  CURSOR jellybot-… ?auto YES 1s   14.7%  1.7%   driver/cli/src/index.ts cursor --resume 5a2fba34-4b5e-4762-8e   ~/.

 ✓ IDLE & READY (8)
 ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
   ●  CLAUDE hapi       $sonn —        0.5%   0.4%   ~/coding/hapi
   ...

 ○ INACTIVE (68)
 ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
   ○  ?      ?          ?—    —        —      —      hub inactive
   ...

 ● OK    ◆ WORKING    ▲ STUCK?    ☠ ZOMBIE   │  $ premium  · economy  ? auto  │  --watch  --json  --plain  ◉ LIVE 1s
Σ 79 sessions (incl inactive) · j/k to scroll  i hide inactive
```

The frame is padded to exactly the viewport height so nothing scrolls
the header off (see #12 / #13).

## Header region (rows 1-13)

The first 13 rows are fixed chrome - they never paginate, they never
scroll. Everything else flows below.

### Logo (left column, rows 2-10)

The HAPI block letters. Color gradient runs vertically from cyan to
light cyan-blue. Purely cosmetic; no operational meaning. Width is
fixed (`LOGO_W`); the rest of the row is the BUILD panel and chart.

### BUILD + STATE panel (middle column)

Border color is purple (`fg141`), title bold-pink (`fg213`).

```
BUILD + STATE
──────────────────────────
app 0.19.0  p1  cli 0.18.4
git driver/integration@3039d1c*
hub active:6373  run active:6836
web D3OBJS52@06-02 06:58  MISMATCH
proxmox  running pid 6836 :40677
sessions 79   ◆WORKING 3 ●OK 8 ○INACTIVE 68
```

Line by line:

| Line | Means |
|------|-------|
| `app 0.19.0  p1  cli 0.18.4` | hub app version, prod pillar, cli version reported by the hub |
| `git driver/integration@3039d1c*` | last seen driver branch + short SHA; `*` = dirty working copy |
| `hub active:6373  run active:6836` | hub's recorded "active" pid vs the process actually running. Mismatch (different numbers) here means the hub thinks one process is running but a different one actually is - usually a restart in flight |
| `web D3OBJS52@06-02 06:58  MISMATCH` | last web build hash + timestamp. `MISMATCH` warning when the web build doesn't match the running binary - rebuild or restart needed |
| `proxmox  running pid 6836 :40677` | host name + the pid + port of the live hub process |
| `sessions 79   ◆WORKING 3 ●OK 8 ○INACTIVE 68` | live counters for the full dataset (visible + hidden), so counts stay honest even when the `i` toggle is hiding inactives |

### AGENTS chart (right column)

```
┌ AGENTS ─────────────────────┐
│   ┤ ── working 3   ── peak 3│
│  3┤─────────────────────────│
│   ┤                         │
│  2┤                         │
│  1┤                         │
│   ┤                         │
│  0┤                         │
│   ┤-76s -51s    -25s     -0s│
└─────────────────────────────┘
```

- **Title** (`AGENTS`, pink) - chart name
- **Legend row** - `── working N` (green) is the live count of WORKING
  agents; `── peak N` (magenta) is the peak working count in the
  visible window. `N` updates every refresh tick.
- **Y axis** - 0 at the bottom, max_y at the top; tick labels on the
  left. Auto-scales with peak.
- **Plot area** - nvtop-style step line plot. Green line is the
  working series, magenta is peak.
  - **Overlap rendering**: when `working == peak` at the same column,
    the cell is striped green/magenta so both series remain visible
    (see #14). Without this, the second-drawn series silently
    overwrites the first and you'd think peak isn't being tracked.
- **X axis** - time in seconds-ago. Newest sample on the right
  (`-0s`), oldest on the left. The window length is
  `HAPI_WATCH_SEC` * `plot_width`.

### Hotkey hint (row 11)

```
 j/k ↑↓ select · TAB alert · g/G top/bot · i hide inactive · q quit
```

Rendered at column 0 so the long string doesn't wrap under the chart
column. Each key is cyan, the description dimmed:

| Key | Action |
|-----|--------|
| `j` / `↓` | move cursor down one visible row |
| `k` / `↑` | move cursor up one visible row |
| `TAB`     | jump cursor to next ATTENTION row |
| `g`       | cursor to top of visible list |
| `G`       | cursor to bottom of visible list |
| `i`       | toggle INACTIVE section visibility |
| `q`       | quit |

When a row is selected, this line is replaced by the SID/AG/RUN detail
for that row (see "Detail row" below).

### Detail row (alternative to hotkey hint)

When you select a row with `j`/`k`, the hotkey hint is replaced by:

```
                                                                            SID a1b2c3d4  AG e5f6g7h8  RUN 6836
```

- **SID** - first 8 chars of the session id (HAPI's unique session
  identifier)
- **AG** - first 8 chars of the `agentSessionId` (the agent runtime's
  internal session id, often the cursor/claude/codex resume token)
- **RUN** - host pid running this agent

### Status sub-line (row 12)

```
  ◴ ONLINE  hub https://hapi.tail9944ee.ts.net  ·  2026-06-02 14:55:48  ·  stuck>20m
```

| Fragment | Means |
|----------|-------|
| `◴ ONLINE` | pulse glyph cycles every tick to confirm the loop is live; ONLINE in green means hub is reachable. `⚠ OFFLINE` in red means the last fetch failed |
| `hub <url>` | the HAPI hub URL being polled (set via `HAPI_HEALTH_HUB` or `--hub`) |
| `2026-06-02 14:55:48` | local timestamp of this frame |
| `stuck>20m` | the threshold the watch loop uses to flag an agent as `STUCK?` - "thinking for more than 20 minutes" |
| `filter:<expr>` | (only if filter active) the active project/flavor filter |

### Separator (row 13)

`═══════════...` in purple - visual break between header and table.

## Table region

Three sections, in priority order. All share the same column layout.

### Column layout

```
   S  TYPE   PROJ       MODL  THINK    CPU    RAM    NOTE
```

| Column | Width | Means |
|--------|-------|-------|
| `S`    | 1     | status glyph: `◆`=WORKING, `●`=OK, `▲`=STUCK?, `☠`=ZOMBIE, `○`=INACTIVE |
| `TYPE` | 8     | flavor badge: ` CURSOR `, ` CLAUDE `, ` CODEX  `. Cursor rows still on legacy stream-json (pre-ACP migration) render as ` cursor ` lowercase in dim gray, and their NOTE column carries `[legacy stream-json]` so operators can spot migration holdouts (#28). |
| `TYPE` | 6     | agent flavor: `CURSOR`, `CLAUDE`, `CODEX`, `GEMINI`. Colored badge in interactive mode |
| `PROJ` | 10    | last path segment of the project working dir, truncated with `…` |
| `MODL` | 5     | model class indicator: `$sonn`=Claude Sonnet (premium), `$g5.5`=GPT-5 (premium), `$gemi`=Gemini Pro (premium), `?auto`=automatic/unknown selection, `?—`=no model reported |
| `THINK`| 9     | think state: `YES Ns` (currently thinking, N seconds elapsed), `—` (idle), `YES…` (very long-running) |
| `CPU`  | 6     | live CPU% reported by the agent's host process |
| `RAM`  | 6     | live RAM% reported by the agent's host process |
| `NOTE` | rest  | best-effort context, truncated with `…` to fit. Idle rows show the HAPI session title (`metadata.name`) when set, falling back to the working directory - lets you distinguish multiple agents in the same repo (#42). Attention rows show the agent process command line. |

### ATTENTION REQUIRED section

Section header in bold-yellow. Shows agents in `STUCK?`, `ZOMBIE`,
or `WORKING` states - anything you might need to look at.

```
 ⚡ ATTENTION REQUIRED (3)
   S  TYPE   PROJ       MODL  THINK    CPU    RAM    NOTE
 ───────────────────────────────────────────────────────────────
   ◆  CURSOR hapi       ?auto YES 2s   9.0%   0.7%   ursor --resume d9c3d739-…
```

- Sort order: stable first-seen queue. The first time a session
  enters any attention status it claims a slot and stays there until
  it leaves the attention list entirely. A `WORKING` → `STUCK?`
  transition keeps the row in place (the badge changes, position
  doesn't) - this is deliberate, so multi-line marquee notes stay
  readable as rows around them transition (#23).
- This section is never paginated - all alerts are shown in full.
- Sessions on remote machines (Windows install, second box) can
  reach `WORKING` / `STUCK?` but never `ZOMBIE` - the local process
  check doesn't apply to remote hosts (#25).

### IDLE & READY section

Section header in bold-green.

```
 ✓ IDLE & READY (8)
 ───────────────────────────────────────────────────────────────
   ●  CLAUDE hapi       $sonn —        0.5%   0.4%   ~/coding/hapi
   ...
 … +5 idle below (HAPI_HEALTH_IDLE_MAX to raise cap)
```

- Sort order: stable alphabetical by project → flavor → sid (so the
  list doesn't reshuffle on CPU/RAM jitter).
- **Paginated**: when there are more rows than fit the viewport, only
  a window is shown. Indicators:
  - `… +N idle above` - N rows hidden above the window (cursor scrolled past)
  - `… +N idle below` - N rows hidden below; raise `HAPI_HEALTH_IDLE_MAX` to fit more

### INACTIVE section (only when `i` toggled on)

Section header in dim-gray.

```
 ○ INACTIVE (68)
 ───────────────────────────────────────────────────────────────
   ○  ?      ?          ?—    —        —      —      hub inactive
   ...
 … +64 inactive below
```

- Hidden by default. Press `i` to toggle.
- Same column layout. INACTIVE agents have no live process so most
  cells show `—`.
- Paginated the same way as IDLE; the two sections share one viewport
  budget so the bottom region always fits the pane.

## Footer region

Two lines fixed at the bottom.

### Legend line

```
 ● OK    ◆ WORKING    ▲ STUCK?    ☠ ZOMBIE   │  $ premium  · economy  ? auto  │  --watch  --json  --plain  ◉ LIVE 1s
```

Three groups separated by `│`:

1. **Status legend** - the four state glyphs with their meanings.
2. **Model class legend** - `$ premium` (paid premium model), `· economy` (free/cheap tier), `? auto` (model not reported / auto-routing).
3. **Mode indicators** - which CLI flags are active. `◉ LIVE Ns` shows the live refresh interval in seconds (`HAPI_WATCH_SEC`).

### Σ summary line

```
Σ 79 sessions (incl inactive) · j/k to scroll  i hide inactive
```

- `Σ N sessions` - total row count being shown right now
- `(incl inactive)` shown only when the `i` toggle is on
- `+N inactive hidden` shown when the toggle is off and there are
  hidden inactives
- `j/k to scroll` - reminder that the bottom region paginates
- `i show|hide inactive` - current toggle state and what `i` will do

## Color cheat sheet

| Color | Meaning |
|-------|---------|
| green (`fg46`) | OK / working / live data / CPU healthy / IDLE & READY header |
| magenta (`fg201`) | peak chart line / pink accent on AGENTS title |
| pink (`fg213`) | section titles / BUILD bold / AG token highlight |
| yellow (`fg220`) | ATTENTION REQUIRED header / peak count / filter active |
| red (`fg196`) | OFFLINE / quit key / fatal banners |
| cyan (`fg87`) | hotkeys / SID highlight |
| purple (`fg141`) | chart border / BUILD panel border / ═══ separator |
| dim gray (`fg245`) | inactive / labels / non-critical text |

## Toggles and environment

Hotkeys are in the hint line. The relevant environment variables:

| Env | Default | Effect |
|-----|---------|--------|
| `HAPI_WATCH_SEC`        | `15` | refresh interval in seconds (also the chart x-axis bucket size) |
| `HAPI_HEALTH_HUB`       | -    | hub URL (or use `--hub`) |
| `HAPI_HEALTH_STUCK_MIN` | `20` | threshold (minutes) for `STUCK?` flag |
| `HAPI_HEALTH_IDLE_MAX`  | auto | cap on visible idle rows (default: fit viewport) |
| `HAPI_HEALTH_TILE_MIN`  | `44` | min column width for tiled ATTENTION cards |
| `HAPI_HEALTH_LEGACY_CARDS` | `0` | render legacy card layout instead of unified table |
| `HAPI_CHART_STATE`      | tmpdir | sparkline history file path |
| `HAPI_SESSIONS_PLOT`    | bundled | path to the native plotter binary |

See `bash src/hapi-monitor.sh --help` for the full CLI flag list.

## Tip: read this with the screen

If you're learning the interface, run hapi-monitor in one pane and
keep this doc open in another. Every glyph and badge in the live
screen has a corresponding entry above; trace what you see to what
it means.
