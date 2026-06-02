# Repository settings (canonical record)

Snapshot of which GitHub controls are enabled on `heavygee/hapi-monitor`.
Update this file whenever the settings change so the repo's hardening state
is auditable from the code itself.

## Identity

| | |
|---|---|
| Owner | `heavygee` |
| SSH key | `/home/heavygee/.ssh/id_rsa` |
| `gh` CLI | `gh` (heavygee account) |
| Visibility | **public** |

## Branch protection (`main`)

- Require a pull request before merging — ✅
- Require status checks: **`ci`** (aggregate) — ✅
- Require branches to be up to date before merging — ✅
- Require linear history (squash merges only) — ✅
- Allow auto-merge — ✅
- Automatically delete head branches — ✅
- Restrict force pushes — ✅

## GitHub Advanced Security (free for public)

| Control | State |
|---------|-------|
| Secret scanning | enabled |
| Secret scanning push protection | enabled |
| CodeQL default setup | enabled (`javascript-typescript`, `python`, `actions`) |
| Code Quality (preview) | enabled if REST 200; document `unavailable (plan)` if 403 |
| Dependabot alerts | enabled |
| Dependabot security updates | enabled |
| Dependabot version updates | `.github/dependabot.yml` (npm + github-actions, weekly) |
| Private vulnerability reporting | enabled |
| Dependency graph | on by default |

## In-repo CI gates

`.github/workflows/ci.yml` runs:

| Job | Tool | Blocks merge |
|-----|------|---|
| `shellcheck` | shellcheck | ✅ |
| `python-syntax` | `python3 -m py_compile` | ✅ |
| `build-plotter` | gcc | ✅ |
| `node-wrapper` | node | ✅ |
| `smoke` | `test/smoke.sh` | ✅ |
| `secret-scan` | gitleaks | ✅ |
| `owasp-sast` | Semgrep (OWASP Top 10 + project rules) | ✅ |
| `ci` (aggregate) | sum of above | ✅ required for merge |

## Release path

`.github/workflows/release.yml` runs on tag `v*`:

1. Verify tag matches `package.json` version.
2. `npm publish --provenance --access public` (needs `NPM_TOKEN` secret).
3. Cut a GitHub Release with the matching `CHANGELOG.md` section.

**Environment `npm`** holds `NPM_TOKEN`. **No tag pushes until the env is configured.**
See [`NPM_SETUP.md`](NPM_SETUP.md) for the one-time wiring procedure
(token creation, env, secret, optional reviewer gate, dry-run, tag).

## Pages / docs site

Not enabled. README is the docs surface. If we add a marketing site later,
revisit Tier E / Tier E+ in `perfect-github-setup-and-operation`.

## Sponsorship

`.github/FUNDING.yml` → `github: [heavygee]`. **Operator step:** enable
Sponsorships in Settings → General → Features for the sidebar button to
appear.

## Social preview

Placeholder. `.github/social-preview.png` (1280×640) to be generated and
uploaded via Settings → General → Social preview.

## Apply Tier H controls via `gh`

```bash
OWNER=heavygee REPO=hapi-monitor
gh api -X PUT "repos/$OWNER/$REPO/vulnerability-alerts"
gh api -X PUT "repos/$OWNER/$REPO/automated-security-fixes"
gh api -X PUT "repos/$OWNER/$REPO/private-vulnerability-reporting"
gh api -X PATCH "repos/$OWNER/$REPO" --input - <<'EOF'
{"security_and_analysis":{
  "secret_scanning":{"status":"enabled"},
  "secret_scanning_push_protection":{"status":"enabled"},
  "dependabot_security_updates":{"status":"enabled"}
}}
EOF
gh api -X PATCH "repos/$OWNER/$REPO/code-scanning/default-setup" \
  -f state=configured \
  -f 'languages[]=actions' \
  -f 'languages[]=javascript-typescript' \
  -f 'languages[]=python'
gh api -X PATCH "repos/$OWNER/$REPO/code-quality/setup" \
  -f state=configured \
  -f 'languages[]=javascript-typescript' \
  -f 'languages[]=python' || echo "code quality not available on this plan/visibility"
```

## Last reviewed

- Bootstrap: 2026-06-02
