# NPM_SETUP.md

How to wire `heavygee/hapi-monitor` for `v*` tag → npm publish.

`.github/workflows/release.yml` runs on tag `v*`, verifies
`package.json.version` matches the tag, then runs
`npm publish --provenance --access public` inside a GitHub Environment
called `npm`.

**Primary path: Trusted Publishing (OIDC)** - no long-lived token,
GitHub Actions proves identity to npm at publish time. This is what
the workflow uses by default and what npm explicitly recommends for
CI/CD. The legacy token path is documented as a breakglass fallback
at the bottom.

## Pre-flight checks (do these first)

| Check | Command | Pass condition |
|---|---|---|
| Tree is clean | `git status` | "nothing to commit" |
| CI is green on `main` | `gh run list -L 1 -w ci` | `success` |
| Local build works | `npm run build:plotter && npm test` | both exit 0 |
| Dry-run pack looks right | `npm pack --dry-run` | only files listed in `package.json#files` |
| Version was bumped | `node -p "require('./package.json').version"` | matches the tag you're about to push |

## Step 1 - Create the `npm` environment on GitHub

The workflow targets `environment: name: npm`. If the environment is
absent, the job hangs or fails. Create it once:

```bash
OWNER=heavygee REPO=hapi-monitor
gh api -X PUT "repos/$OWNER/$REPO/environments/npm" --input - <<'EOF'
{
  "wait_timer": 0,
  "reviewers": [],
  "deployment_branch_policy": {
    "protected_branches": false,
    "custom_branch_policies": true
  }
}
EOF

gh api -X POST "repos/$OWNER/$REPO/environments/npm/deployment-branch-policies" \
  -f name='v*' -f type='tag'
```

Only refs matching `v*` can deploy to `npm`. A random branch push can
never trigger a publish even if the workflow trigger were bypassed.

**Optional manual gate:** add yourself as a required reviewer so every
publish needs a one-click approval in the Actions UI. Useful as a
"stop the bleeding" switch if anything ever goes sideways:

```bash
USER_ID=$(gh api users/heavygee --jq .id)
gh api -X PUT "repos/$OWNER/$REPO/environments/npm" --input - <<EOF
{
  "wait_timer": 0,
  "reviewers": [{"type": "User", "id": $USER_ID}],
  "deployment_branch_policy": {
    "protected_branches": false,
    "custom_branch_policies": true
  }
}
EOF
```

## Step 2 - Configure npm Trusted Publisher

This is the single security-critical step. Once configured, npm only
accepts publishes that come from this exact GitHub repo + workflow +
environment combo, regardless of which tokens may exist on the account.

1. Sign in to <https://www.npmjs.com>.
2. Browse to <https://www.npmjs.com/package/hapi-monitor/access> →
   **Trusted Publishers** → **Add Trusted Publisher** → **GitHub Actions**.
3. Fill in:

   | Field | Value |
   |---|---|
   | Organization or user | `heavygee` |
   | Repository | `hapi-monitor` |
   | Workflow filename | `release.yml` |
   | Environment | `npm` |

4. Save. No token is generated or copied - npm just records the OIDC
   issuer it will accept.

**First-publish chicken-and-egg:** npm's trusted-publisher form only
appears once the package exists. For a brand-new unpublished package,
do the first publish with a short-lived token (Appendix A), then
configure Trusted Publishing and remove the token. After that all
subsequent publishes are tokenless.

## Step 3 - Verify the workflow is OIDC-ready

`.github/workflows/release.yml` should have:

- `permissions.id-token: write` (lets the runner mint an OIDC token)
- `actions/setup-node` with `node-version: "22"` and `registry-url: https://registry.npmjs.org/`
- An explicit `npm install -g npm@latest` step before `npm publish`
- `npm publish --provenance --access public` with **no** `NODE_AUTH_TOKEN`

### npm CLI version requirement (the gotcha)

Tokenless OIDC publishing requires **npm CLI >= 11.5.1** (Aug 2025).
Older npm versions sign the provenance attestation (which uses the
OIDC token directly via sigstore) but then still demand a bearer token
for the actual `PUT /package` request, and 404 without one.

`actions/setup-node@v6` with `node-version: "20"` ships npm 10.x, which
will fail. `node-version: "22"` is also a 10.x npm. The reliable
recipe is to always force `npm install -g npm@latest` as a workflow
step before any publish - cheap, deterministic, and survives upstream
node-image drift.

## Step 4 - Confirm `package.json#repository.url`

Provenance attestation verifies the package came from this exact repo.
The `repository.url` in `package.json` is the source of truth for that
check:

```json
"repository": { "type": "git", "url": "git+https://github.com/heavygee/hapi-monitor.git" }
```

If you ever rename the GitHub repo or fork it, update `repository.url`
**before** the next tag or `--provenance` will fail.

## Step 5 - Cut a release

```bash
git switch main
git pull --ff-only

# Bump version + write CHANGELOG entry (header must contain the version)
$EDITOR package.json   # "version": "0.1.x"
$EDITOR CHANGELOG.md   # ## 0.1.x - YYYY-MM-DD

git add package.json CHANGELOG.md
git commit -m "chore(release): v0.1.x"
git push origin main

git tag -a v0.1.x -m "v0.1.x"
git push origin v0.1.x
```

Then watch the run:

```bash
gh run watch -R "$OWNER/$REPO"
```

## Step 6 - Verify the publish

```bash
npm view hapi-monitor                        # latest dist-tag should match
npm view hapi-monitor dist.attestations      # provenance present
```

The npm page (<https://www.npmjs.com/package/hapi-monitor>) should show
a green "Provenance" badge linking back to the GitHub Actions run.

## Things that go wrong

| Symptom | Cause | Fix |
|---|---|---|
| `Error: Trusted Publisher not configured` | npm-side Trusted Publisher missing or pointing at wrong workflow/env | Re-do Step 2; verify workflow filename + environment name match exactly |
| `npm error code EOTP` | Workflow is still using the legacy token path AND the token doesn't bypass 2FA | Remove `NODE_AUTH_TOKEN` from `release.yml`; Trusted Publishing doesn't use tokens at all |
| `npm error code E403 - 403 Forbidden` | Trusted Publisher exists but env name in workflow doesn't match the npm-side configuration | Align `environment: name:` in `release.yml` with the npm Trusted Publisher form |
| `tag v0.1.x does not match package.json 0.1.y` | Forgot to bump `package.json` before tagging | Delete tag (`git tag -d v0.1.x && git push --delete origin v0.1.x`), bump, retag |
| `npm error provenance: failed to verify` | Renamed repo, or pushed from a fork, or `repository.url` drifted | Realign `package.json#repository.url` with the actual remote |
| Workflow stuck on "Waiting for review" | Required reviewer configured in env, no approver online | Approve via Actions UI, or remove the reviewer requirement |

---

## Appendix A - Legacy token path (breakglass / first-ever publish)

Use this only if Trusted Publishing isn't yet configured (e.g. the
package doesn't exist on npm yet) or as a fallback if OIDC ever fails.

### Generate a token

1. <https://www.npmjs.com/settings/~/tokens> → **Generate New Token →
   Granular Access Token**.
2. Fill in:

   | Field | Value |
   |---|---|
   | Token name | `hapi-monitor-ci-breakglass` |
   | Expiration | 7-30 days (short - this is a one-shot tool) |
   | Allowed IP ranges | leave blank |
   | Permissions → Packages and scopes | `Read and write` |
   | Packages and scopes | `All packages` (if package doesn't exist yet) or `hapi-monitor` (if it does) |
   | **Bypass 2FA when publishing this package** | **YES** (CI cannot enter an OTP) |

3. Copy the token.

### Wire it up

```bash
gh secret set NPM_TOKEN --repo "$OWNER/$REPO" --env npm --body "npm_xxx"
```

### Restore the workflow

Add this back to the publish step in `release.yml`:

```yaml
- name: Publish to npm with provenance
  run: npm publish --provenance --access public
  env:
    NODE_AUTH_TOKEN: ${{ secrets.NPM_TOKEN }}
```

### Then revert

After the publish succeeds, **revoke the token immediately**, remove
the secret, and restore the OIDC-only version of `release.yml`. Long
lived tokens are a liability; minimise the window they're alive.

## Last reviewed

- 2026-06-02 - migrated primary path to Trusted Publishing (#19)
