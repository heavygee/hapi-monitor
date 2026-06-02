# NPM_SETUP.md

How to wire `heavygee/hapi-monitor` for its first `v*` tag → npm publish.

`.github/workflows/release.yml` runs on tag `v*`, verifies
`package.json.version` matches the tag, then runs
`npm publish --provenance --access public` inside a GitHub Environment
called `npm` that is expected to hold one secret: `NPM_TOKEN`.

If that environment doesn't exist yet, the workflow will fail with
`Error: Input required and not supplied: NODE_AUTH_TOKEN` or it will
publish nothing because the env gate blocks the job. Configure once,
then forget.

## Pre-flight checks (do these first)

| Check | Command | Pass condition |
|---|---|---|
| Name is free on npm | `npm view hapi-monitor` | `404 Not Found` (or you already own it) |
| Tree is clean | `git status` | "nothing to commit" |
| CI is green on `main` | `gh run list -L 1 -w ci` | `success` |
| Local build works | `npm run build:plotter && npm test` | both exit 0 |
| Dry-run pack looks right | `npm pack --dry-run` | only files listed in `package.json#files` |

If `npm view hapi-monitor` returns metadata you don't recognise, the name
is taken — pick a scoped name (`@heavygee/hapi-monitor`) and update
`package.json#name` plus the badges in `README.md` before continuing.

## Step 1 - Create a Granular Access Token on npm

1. Log in to <https://www.npmjs.com>. Enable 2FA if you haven't (Auth
   Only or Auth + Writes — the token still works with either).
2. <https://www.npmjs.com/settings/~/tokens> → **Generate New Token →
   Granular Access Token**.
3. Fill in:

   | Field | Value |
   |---|---|
   | Token name | `hapi-monitor-ci` |
   | Description | `GitHub Actions release.yml — publish only` |
   | Expiration | 90 days (or your policy max — never "no expiry") |
   | Allowed IP ranges | leave blank (GitHub-hosted runners use a wide pool) |
   | Permissions → Packages and scopes | `Read and write` |
   | Packages and scopes → Only select packages | `hapi-monitor` (or `@heavygee/hapi-monitor` if scoped) |
   | Permissions → Organizations | `No access` |

4. Copy the token. It starts with `npm_`. You will not see it again.

Do **not** use a Classic Automation Token unless you have a reason —
granular tokens are scoped to a single package and can't accidentally
publish anything else if leaked.

## Step 2 - Create the `npm` environment on GitHub

The workflow targets `environment: name: npm`. If the environment is
absent, the job hangs in "Waiting for review" or fails with a missing
secret. Create it explicitly:

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

Result: only refs matching the tag pattern `v*` can deploy to `npm`. A
random branch push can never trigger a publish even if someone bypasses
the workflow trigger.

**Recommended (manual gate):** add yourself as a required reviewer so
every publish needs a one-click approval in the Actions UI:

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

For a solo-maintainer public OSS package the reviewer step is overkill
for routine bumps but very useful as a "stop the bleeding" switch if
credentials ever leak. Decide once, document it here.

## Step 3 - Add `NPM_TOKEN` to the environment

```bash
gh secret set NPM_TOKEN \
  --repo "$OWNER/$REPO" \
  --env npm \
  --body "npm_xxx_paste_token_here_xxx"
```

Or via the UI: Settings → Environments → `npm` → Add secret →
`NPM_TOKEN`.

Verify:

```bash
gh api "repos/$OWNER/$REPO/environments/npm/secrets" --jq '.secrets[].name'
# expected: NPM_TOKEN
```

The repo-level `Secrets` page should **not** contain an `NPM_TOKEN`
shadow copy — keep it environment-scoped so the gate is meaningful.

## Step 4 - Link the npm package to this repo (provenance attestation)

`--provenance` only works if the package's npm registry record says it
was published from this exact GitHub repo. For the **first** publish the
link is established automatically by the OIDC attestation. For
subsequent publishes, npm verifies the linkage from
`package.json#repository.url` — already set:

```json
"repository": { "type": "git", "url": "git+https://github.com/heavygee/hapi-monitor.git" }
```

No further action. If you ever rename the GitHub repo or fork it, update
`repository.url` **before** the next tag or `--provenance` will fail.

## Step 5 - Cut `v0.1.0`

```bash
git switch main
git pull --ff-only

# Bump version + write CHANGELOG entry first (header MUST contain the version)
$EDITOR package.json   # "version": "0.1.0"
$EDITOR CHANGELOG.md   # ## 0.1.0 - YYYY-MM-DD

git add package.json CHANGELOG.md
git commit -m "chore(release): v0.1.0"
git push origin main

git tag -a v0.1.0 -m "v0.1.0"
git push origin v0.1.0
```

Then watch the run:

```bash
gh run watch -R "$OWNER/$REPO"
```

If you added a reviewer to the env (Step 2 optional), the job pauses
until you approve in the Actions UI.

## Step 6 - Verify the publish

```bash
npm view hapi-monitor
npm view hapi-monitor dist.attestations    # provenance present?
```

The npm page (`https://www.npmjs.com/package/hapi-monitor`) should show
a green "Provenance" badge linking back to the GitHub Actions run.

## Rotating the token

Granular tokens expire. Add a calendar reminder for `now + 75 days` (15
days of headroom). Rotation flow:

1. Generate replacement token (Step 1).
2. `gh secret set NPM_TOKEN --repo $OWNER/$REPO --env npm --body "..."`
3. Revoke the old token on npm.
4. Trigger a no-op tag push (`v0.x.y+1`) only if you want to verify —
   not required.

## Optional upgrade - Trusted Publishers (no token at all)

npm now supports OIDC-only publishing (Trusted Publishers, GA late
2025). When ready:

1. <https://www.npmjs.com/package/hapi-monitor/access> → Trusted
   Publishers → Add → GitHub Actions.
2. Repo: `heavygee/hapi-monitor`. Workflow: `release.yml`. Environment:
   `npm`.
3. Remove `NPM_TOKEN` secret from the env and delete the
   `NODE_AUTH_TOKEN` line from `release.yml`. The OIDC token from
   `id-token: write` (already in the workflow) is sufficient.

Defer this until after `v0.1.0` ships. Token path works today and
matches the rest of our org.

## Things that go wrong

| Symptom | Cause | Fix |
|---|---|---|
| `Error: Input required and not supplied: NODE_AUTH_TOKEN` | `NPM_TOKEN` missing from env or stored at repo level instead | Re-run Step 3 with `--env npm` |
| `npm error code E403 - 403 Forbidden - You do not have permission` | Granular token scoped to a different package than the one you're publishing | Regenerate token with the right package in the allow-list |
| `npm error 404 Not Found - PUT https://registry.npmjs.org/hapi-monitor` | First publish but `access` isn't `public` for a scoped name | Already handled - `publishConfig.access` is `public` in `package.json` |
| `tag v0.1.0 does not match package.json 0.0.x` | Forgot to bump `package.json` before tagging | Delete tag (`git tag -d v0.1.0 && git push --delete origin v0.1.0`), bump, retag |
| `npm error provenance: failed to verify` | Renamed repo, or pushed from a fork, or `repository.url` drifted | Realign `package.json#repository.url` with the actual remote |
| Workflow stuck on "Waiting for review" | Required reviewer configured in env, no approver online | Approve via Actions UI, or remove the reviewer requirement |

## Last reviewed

- Bootstrap: 2026-06-02
