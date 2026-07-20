# Onboarding (and offboarding) an app

Use the **`onboard-app` skill** (or `scripts/onboard-app.sh` directly). The
platform deploy role trusts the whole org (`repo:<org>/*`), so adding a repo
needs **no platform/CDK change** — just the secret + caller workflows. The
script sources `project.env` and derives the CICD stack name from it.

## The three modes

### image — deploy a preview from an existing image

```bash
scripts/onboard-app.sh image --image <ecr-ref:tag> --pr <n> \
  [--secret <k8s-secret>] [--base-domain <d>] [--port <p>]
```

Probes the image and **auto-detects** container port, routing mode (`host` if
the app serves at `/`, `path` if it bakes a basePath), and whether `/api/health`
returns a `sha` (strict fresh-deploy gate) or not (probe-only readiness). If
`--secret` is given, its keys are copied into the namespace and wired as env.
Prints the preview URL and a `kubectl port-forward` line for browser access.

```bash
scripts/onboard-app.sh image \
  --image <ACCOUNT_ID>.dkr.ecr.<region>.amazonaws.com/<org>/app:<sha> \
  --pr 42 --secret example-app-secret
```

### repo — scaffold a repo for automatic previews

```bash
scripts/onboard-app.sh repo --repo <org/app> [--routing path|host]
```

Writes `.github/workflows/preview.yml` + `preview-teardown.yml` (ALB host and
ECR repo auto-filled), prints the exact `gh secret set AWS_DEPLOY_ROLE_ARN ...`
command, and lists any contract gaps. Then open a PR.

### offboard — remove an app's previews

```bash
# dry-run by default — shows what WOULD happen, changes nothing:
scripts/onboard-app.sh offboard --pr <n> [--repo <org/app>] [--purge-ecr]
# apply:
scripts/onboard-app.sh offboard --pr <n> --yes
```

- **Default:** tear down the app's `pr-*` preview namespaces + `DROP` their
  `pr_<n>` schemas.
- **`--purge-ecr`:** also delete the preview ECR repo.
- **`--repo`:** also remove the app repo's `AWS_DEPLOY_ROLE_ARN` secret + caller
  workflows.
- **Safety:** only ever touches `pr-<n>` namespaces (never a prod namespace,
  `kube-*`, ...); dry-run unless `--yes`. The org-wide OIDC trust is shared, so
  it is **not** revoked when you offboard one repo.

## The app contract

The script **auto-adapts** to most of this; the table is what makes a preview
fully featured vs. degraded.

| # | Requirement | Hard? | If missing |
| --- | --- | --- | --- |
| 1 | Listens on a known container port (`--port`, default 3000) | **HARD** | won't serve |
| 2 | Serves `/api/health` returning HTTP 200 | **HARD** | readiness never passes |
| 3 | `/api/health` returns `{"sha": "<build GIT_SHA>"}` | soft | falls back to **probe-only** readiness (no strict fresh-deploy gate) |
| 4 | path mode: `basePath` baked at build (`PREVIEW_BASE_PATH`) | soft | script auto-picks **host mode** (serves at `/`) instead |
| 5 | Runs as non-root UID 1000 | **HARD** | `CreateContainerConfigError` |
| 6 | Tolerates a read-only rootfs (writes only `/tmp`, `/app/.next/cache`) | **HARD** | crashes on write |
| 7 | Reads `DATABASE_URL` if it needs a DB | soft | DB features off; app still healthy (the DB is optional) |

A full-contract app (like the reference workload) gets path-mode + the strict
SHA gate. A prod app built for elsewhere gets host-mode + probe-only — and still
works with **zero code changes**. Requirement 7 is soft because the database is
optional; an app that needs no DB skips it entirely.

## Getting a PR's preview URL

`skills/get-pr-preview-endpoint/` is a **droppable** skill — copy the folder into
any onboarded repo. It reads the `preview/pr-<N>` GitHub Deployment and prints
its `environment_url` (gh-only, no platform checkout):

```bash
./get-pr-preview-endpoint.sh                          # auto-detects repo + PR
./get-pr-preview-endpoint.sh --pr 42 --wait 300       # wait for it to be ready
./get-pr-preview-endpoint.sh --pr 42 --sha $(git rev-parse HEAD)  # fresh-deploy gated
./get-pr-preview-endpoint.sh --pr 42 --doctor         # diagnose why there's no URL
```

Use it in another repo's CI to run tests against the live preview (see the
skill's `SKILL.md`). The `preview-iterate` skill does the same, with iteration —
see [`agent-loop.md`](./agent-loop.md).

## Browser access (no DNS)

In path-mode clusters the preview hostnames have no Route 53 record. To open a
preview in a browser:

```bash
kubectl port-forward -n pr-<n> svc/web 8<n>:80    # then open http://localhost:8<n>/
```

The script prints this line. CI/tests reach the real URL through the shared ALB
(host header in path mode, real DNS in host mode). For host mode without a
public domain, cross-reference `scripts/verify-host-mode.sh` and
[`host-mode.md`](./host-mode.md).
