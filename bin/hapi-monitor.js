#!/usr/bin/env node
/*
 * hapi-monitor — Node CLI wrapper.
 *
 * This binary does ~nothing exciting: it locates the bundled bash entrypoint
 * inside the npm package (or local checkout) and `exec`s it with whatever
 * args the user passed, forwarding stdio + exit code. The actual TUI is
 * Python + (optionally) a native C plotter — this wrapper exists so the tool
 * can be installed via `npm i -g hapi-monitor` / `npx hapi-monitor` like any
 * other modern CLI, instead of asking operators to clone a repo and chmod a
 * .sh file by hand.
 */
'use strict';

const { spawn } = require('node:child_process');
const path = require('node:path');
const fs = require('node:fs');
const process = require('node:process');

const SCRIPT = path.resolve(__dirname, '..', 'src', 'hapi-monitor.sh');

if (!fs.existsSync(SCRIPT)) {
  process.stderr.write(
    `hapi-monitor: bundled script not found at ${SCRIPT}\n` +
    `  the npm package may be incomplete — please reinstall, or file an issue at\n` +
    `  https://github.com/heavygee/hapi-monitor/issues\n`,
  );
  process.exit(1);
}

// Check bash is present. Linux/macOS always have it; pure-Windows shells don't,
// and the script uses bash-only syntax (associative arrays, [[ ]], etc.) so
// there's no portable fallback. WSL counts as Linux for our purposes.
const bash = process.env.HAPI_MONITOR_BASH || 'bash';

const child = spawn(bash, [SCRIPT, ...process.argv.slice(2)], {
  stdio: 'inherit',
  // Inherit env; the bash script reads HAPI_HUB_URL / HAPI_JWT / etc.
  env: process.env,
});

child.on('error', (err) => {
  if (err.code === 'ENOENT') {
    process.stderr.write(
      `hapi-monitor: '${bash}' not found on PATH.\n` +
      `  This tool needs bash + python3 (Linux, macOS, or WSL).\n` +
      `  Override the bash binary with HAPI_MONITOR_BASH=/path/to/bash if it lives somewhere unusual.\n`,
    );
    process.exit(127);
  }
  process.stderr.write(`hapi-monitor: failed to spawn '${bash}': ${err.message}\n`);
  process.exit(1);
});

child.on('exit', (code, signal) => {
  if (signal) {
    // Re-raise the signal to ourselves so callers see the right exit cause.
    process.kill(process.pid, signal);
    return;
  }
  process.exit(code ?? 0);
});

// Forward Ctrl-C / SIGTERM down to the child so it can clean up alt-screen state.
for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
  process.on(sig, () => {
    if (!child.killed) child.kill(sig);
  });
}
