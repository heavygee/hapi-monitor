# Security policy

## Supported versions

`hapi-monitor` releases follow semver. Security fixes land in the latest
minor of the current major. Older majors get patches only for critical
issues actively exploited in the wild.

| Version | Supported |
|---------|-----------|
| `0.x`   | ✅ (current) |

## Reporting a vulnerability

**Please do not file public GitHub issues for security problems.**

Use one of these private channels:

1. **GitHub Security Advisories** (preferred):
   [Report a vulnerability](https://github.com/heavygee/hapi-monitor/security/advisories/new)
   — keeps disclosure private until a fix is ready.
2. **Email:** `hapi-monitor-security@heavygee.com`

Please include:

- the version (`hapi-monitor --version` or commit SHA)
- a minimal reproduction (terminal output, env vars, hub config relevant
  to the issue)
- your assessment of impact and any suggested mitigation

We aim to acknowledge within 5 working days and to publish a fix within
30 days for confirmed issues. We'll keep you updated and credit you (or
keep you anonymous) in the advisory at your preference.

## Threat model — what's in / out of scope

**In scope:**

- The bash + Python + C source in this repo.
- The npm wrapper (`bin/hapi-monitor.js`).
- The release / CI workflows in `.github/`.

**Out of scope:**

- The upstream [tiann/hapi](https://github.com/tiann/hapi) hub itself.
  Report hub issues to that project.
- Misconfiguration of the operator's environment (leaked `cliApiToken`
  in shell history, world-readable `~/.hapi/settings.json`, etc).
- Vulnerabilities in third-party tools we shell out to (`tailscale`,
  `systemctl`, `git`, `cc`, `bash`, `python3`).

## Common-sense hygiene

This script reads a `cliApiToken` from `~/.hapi/settings.json` (or
`HAPI_JWT` from the environment) and uses it to authenticate against your
HAPI hub. Treat that file like any other credential:

```bash
chmod 600 ~/.hapi/settings.json
```

The auto-detected `HAPI_HUB_PUBLIC_URL` is cached in
`$TMPDIR/hapi-hub-public-url.cache`. It contains only the public
hostname, no credentials.

## Past advisories

None yet. This section will populate as advisories are published.
