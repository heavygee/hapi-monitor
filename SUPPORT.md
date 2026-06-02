# Getting help

## I have a question / I'm stuck

Open a [GitHub Issue](https://github.com/heavygee/hapi-monitor/issues/new/choose)
and tag it with `question`. Please include:

- `hapi-monitor --version` (or commit SHA if running from source)
- the hub URL you're targeting (or a redacted form)
- terminal output / screenshot of the error or unexpected behaviour
- what you expected to happen

## I found a bug

Use the [bug report template](https://github.com/heavygee/hapi-monitor/issues/new?template=bug_report.yml).

## I have a feature idea

Use the [feature request template](https://github.com/heavygee/hapi-monitor/issues/new?template=feature_request.yml).
Note we triage hard against scope creep — this tool is intentionally focused
on terminal monitoring of an existing HAPI hub, not a general-purpose agent
dashboard.

## I think there's a security issue

**Do not open a public issue.** See [SECURITY.md](SECURITY.md) for the
private reporting channels.

## I want to use this with a different HAPI fork

The script talks to a hub via the public `/api/sessions` and `/api/auth`
endpoints. If your fork keeps that surface, it should just work — point
`HAPI_HUB_URL` at it and configure auth. If your fork has changed those
endpoints, open an issue describing what you're trying to do.

## I want to integrate this into my own dashboard

Use `hapi-monitor --json`. It emits machine-readable session + build data
without the TUI chrome, suitable for piping into your own visualisation.
