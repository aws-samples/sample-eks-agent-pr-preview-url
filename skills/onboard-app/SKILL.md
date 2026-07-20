---
name: onboard-app
description: Onboard or offboard an app to the pr-preview PR-preview platform. Use when asked to add/onboard an app or repo to PR previews, give an app a preview URL, deploy an ECR image as a preview, scaffold preview workflows for a repo, or tear down / offboard / remove an app's previews. Backed by scripts/onboard-app.sh.
---

# onboard-app

One-step onboarding/offboarding for the PR-preview platform. The backing script
`scripts/onboard-app.sh` auto-adapts to whatever the app is, so even
apps not built for this platform "just work."

The platform deploy role trusts the **whole org** (`repo:<org>/*`), so
onboarding a repo needs **no CDK/platform change** — just the secret + workflows.

## Pick the mode

- **The app/image is already in the cluster or ECR** (e.g. example-app's prod
  image) and you want a live preview now → **image mode**.
- **An app repo** should deploy previews automatically on every PR → **repo mode**
  (scaffolds the caller workflows).
- **Remove an app's previews** → **offboard mode**.

## image mode — deploy a preview from an image

```bash
scripts/onboard-app.sh image --image <ecr-ref:tag> --pr <n> \
  [--secret <k8s-secret>] [--base-domain <d>] [--port <p>]
```
It probes the image and **auto-detects**: container port, routing mode (`host`
if the app serves at `/`, `path` if it bakes basePath), and whether
`/api/health` returns a `sha` (strict fresh-deploy gate) or not
(probe-only readiness). If `--secret` is given, its keys are copied into the
namespace and wired as env. Prints the preview URL + a `kubectl port-forward`
line for browser access (no DNS).

## repo mode — scaffold a repo onto the platform

```bash
scripts/onboard-app.sh repo --repo <org/app> [--routing path|host]
```
Generates `.github/workflows/preview.yml` + `preview-teardown.yml` (ALB host and
ECR repo auto-filled), prints the exact `gh secret set AWS_DEPLOY_ROLE_ARN ...`
command, and prints the image **contract** to meet (port, `/api/health` `sha`,
basePath in path mode, non-root UID 1000, read-only rootfs). See
`docs/onboarding.md`.

## offboard mode — remove an app's previews

```bash
# dry-run by default — shows what WOULD happen, touches nothing:
scripts/onboard-app.sh offboard [--pr <n>] [--repo <org/app>] [--purge-ecr]
# apply:
scripts/onboard-app.sh offboard --pr <n> --yes
```
Default: tears down the app's `pr-*` preview namespaces + `DROP`s their `pr_<n>`
schemas. Opt-in: `--purge-ecr` (delete the preview ECR repo), `--repo` (prints/
deletes the GitHub secret + caller workflows). **Safety:** dry-run unless
`--yes`; it only ever acts on `pr-<n>` namespaces (never `example-app-prod`,
`kube-*`, etc.). The org-wide OIDC trust is shared, so it is **not** revoked for
one repo.

## Notes

- Verify a live preview the way the platform does: `curl` the URL's `/api/health`
  (200) and a real route. For browser access without DNS, use the printed
  `kubectl port-forward`.
- Full contract + both routing modes: `docs/onboarding.md`.
