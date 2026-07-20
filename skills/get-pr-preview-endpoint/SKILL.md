---
name: get-pr-preview-endpoint
description: Resolve the live per-PR preview URL for a repo whose pull requests deploy to the pr-preview platform (EKS/Kubernetes, NOT a hosted PaaS). Use when someone asks "what's the preview URL/link/endpoint for this PR", "where is PR #N deployed", "is the preview ready", or wants to run smoke tests / curl / Playwright against a PR's live preview, or needs the base URL for a PR environment in CI. It reads the GitHub Deployment named `preview/pr-<N>` and prints its environment_url. Do NOT use for hosted-PaaS previews (managed frontend/deploy platforms), for production URLs, or in a repo that does not build EKS PR previews. gh CLI only; works standalone.
---

# get-pr-preview-endpoint

Prints the live **preview URL** for a pull request whose preview is deployed by
the **pr-preview** platform (per-PR ephemeral environments on EKS/Kubernetes,
reached through a shared ALB). It reads the **GitHub Deployment** the preview
workflow writes for environment `preview/pr-<N>` and returns that deployment's
`environment_url`. **Self-contained and droppable**: a single bash script
depending only on the GitHub CLI (`gh`) — copy this folder into any onboarded
repo; it does not need the platform checkout.

### `--doctor` — diagnose why there's no URL (the discovery aid)
Using a preview resolver cold used to require manual discovery ("is there a
cluster? is the repo onboarded? why `no-deployment`?"). `--doctor` answers that
chain in one run and prints the **specific** missing link instead of a bare
`no-deployment`:

```bash
./get-pr-preview-endpoint.sh --repo <org/repo> --pr <n> --doctor
# checks: gh auth · repo onboarded (a workflow calls preview.yml / a preview/pr-* deployment exists)
#         · the deployment for THIS PR · SHA freshness (with --sha) · the resolver's bottom-line state
```

Exit reasons (`--json` `state`): `success | not-onboarded | no-deployment-yet |
awaiting-sha:<conclusion> | deploy-pending:<state> | deployment-no-url`. Each is
actionable — e.g. `not-onboarded` means the repo doesn't build EKS PR previews
(add a caller of `preview.yml`, or this skill doesn't apply).

## When to use this skill

Use it when you need the live URL of a PR's preview — for example:
- "What's the preview URL / link / endpoint for this PR?" / "Where is PR #42 deployed?"
- "Is the preview ready yet?" (use `--wait`)
- "Run the smoke tests / curl / Playwright against the PR preview" (the URL is the base)
- A CI step needs the preview base URL to test against.

## When NOT to use it

- The repo's previews come from a **hosted PaaS / managed frontend-deploy
  platform**, or any non-EKS platform — this reads EKS `preview/pr-<N>` GitHub
  Deployments only; for those, use that provider's CLI/API instead.
- You want the **production** URL (this is per-PR previews only).
- The repo is **not onboarded** to the pr-preview platform (its PRs don't
  build previews) — the script will just print `no-deployment`.

If unsure whether a repo uses this platform: run the script; `no-deployment`
means it doesn't (or the preview hasn't built yet), and the skill is harmless.

## Use

```bash
# inside a repo / PR checkout — auto-detects repo + PR:
./get-pr-preview-endpoint.sh

# explicit:
./get-pr-preview-endpoint.sh --repo <org/repo> --pr <n>

# wait up to 5 min for the preview to be ready, then print the URL:
./get-pr-preview-endpoint.sh --pr <n> --wait 300

# SHA-gate (only return once THIS commit's preview is green — never a stale one):
./get-pr-preview-endpoint.sh --pr <n> --sha "$(git rev-parse HEAD)"

# machine-readable:
./get-pr-preview-endpoint.sh --pr <n> --json    # {"url":...,"state":...,...}
```

Exit 0 + the URL on stdout when ready; exit 1 when there's no ready preview
(prints the reason — `no-deployment`, `awaiting-sha:...`, etc. — to stderr).

## In another repo's CI (run tests against the preview)

After the reusable `preview.yml` job, add a step:

```yaml
- name: Resolve + test the preview
  run: |
    URL="$(./.github/skills/get-pr-preview-endpoint/get-pr-preview-endpoint.sh \
            --pr "${{ github.event.pull_request.number }}" --sha "${{ github.event.pull_request.head.sha }}" --wait 300)"
    curl -fsS "$URL/api/health"
    # npx playwright test --config=... BASE_URL="$URL"
```

## Requirements

- `gh` authenticated with read access to the repo's Deployments + Checks
  (in Actions, the default `GITHUB_TOKEN` with `deployments: read, checks: read`).
- The repo must be **onboarded** to the pr-preview platform — i.e. it has a
  GitHub Actions workflow (a caller of the platform's reusable `preview.yml`)
  that, on each PR, builds the app and writes a GitHub Deployment to environment
  `preview/pr-<N>`. You can confirm by checking the repo's
  `.github/workflows/*.yml` for `uses: <org>/pr-preview/.github/workflows/preview.yml`,
  or just run this script — `no-deployment` means it isn't onboarded (or hasn't
  built yet). If it needs onboarding, see the platform's `docs/onboarding.md` /
  the `onboard-app` skill.

## Notes

- The URL is the platform's `environment_url`. In path-mode clusters with no DNS
  it's an ALB hostname usable by `curl`/tests; for a browser use the platform's
  `kubectl port-forward` line.
- `--sha` enforces the fresh-deploy invariant: it won't hand back the
  reused URL until the `preview` Check Run for that exact commit is `success`.
