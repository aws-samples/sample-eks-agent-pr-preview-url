<!-- Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved. -->
<!-- SPDX-License-Identifier: MIT-0 -->
# GitHub Actions: how it works, how to set it up, and how to test it

This is the guide for anyone who deployed the infrastructure and then asked:
**"it's all GitHub Actions — so how do I actually run and test it?"**

The short answer: the workflows in **this** repo are a *library*, not a pipeline
that runs by itself. Nothing here fires when you push to this repo. You exercise
the platform from a **second (app) repo** whose pull requests get previews — or,
for a first sanity check with no GitHub and no AWS at all, from the local **kind**
loop. Both are covered below.

- [1. The mental model — two repos](#1-the-mental-model--two-repos)
- [2. How it works (the four workflows)](#2-how-it-works-the-four-workflows)
- [3. Setup — wiring GitHub to your cluster](#3-setup--wiring-github-to-your-cluster)
- [4. Testing it](#4-testing-it)
- [5. Monitoring a run](#5-monitoring-a-run)
- [6. Troubleshooting](#6-troubleshooting)

---

## 1. The mental model — two repos

There are **two roles**, and they are almost always two different repositories:

| Role | Repo | Contains | What runs here |
| --- | --- | --- | --- |
| **Platform** | this repo | The **reusable** workflows (`on: workflow_call`), the app, chart, CDK, scripts | `ci.yml` only (the test gate). The preview workflows do **not** self-trigger. |
| **App** | *your* repo (the thing you want previews of) | A ~5-line **caller** workflow per event | The previews: open a PR here → a preview is built and deployed. |

> **This is the #1 point of confusion.** `preview.yml`, `preview-teardown.yml`,
> and `preview-agent.yml` all start with `on: workflow_call` — they are meant to
> be *called by* another workflow, so opening a PR **in the platform repo does
> nothing**. You must point an app repo's caller workflow at them and open a PR
> **there**. (The one exception is `preview-sweep.yml`, which is a standalone
> scheduled job — see below.)

You can use this very repo as the app repo for a test (that's what the
reference app in `app/` is for), but you still have to add the caller workflows
and the deploy-role secret to it — see [Setup](#3-setup--wiring-github-to-your-cluster).

---

## 2. How it works (the four workflows)

All four live in [`.github/workflows/`](../.github/workflows/).

### `preview.yml` — build + deploy one PR's preview
Trigger (in the app repo): `pull_request` → `opened`, `synchronize`, `reopened`.

1. **Creates a GitHub Deployment** for `preview/pr-<N>` and marks it
   `in_progress` (so the PR shows an environment immediately).
2. **Assumes the AWS deploy role via OIDC** (no long-lived keys), logs in to ECR.
3. **Builds + pushes** the app image, tagged `sha-<short>`. In *path mode* it
   bakes `basePath=/pr-<N>` as a build arg.
4. **`helm upgrade --install`** into namespace `pr-<N>`, labelled so the sweep can
   find it. Uses `--atomic` + a bounded retry so a failed attempt rolls back clean.
5. **SHA-gated readiness** ([`scripts/ci-wait-ready.sh`](../scripts/ci-wait-ready.sh)):
   polls the **real** preview URL until `/api/health` returns **200 AND the pushed
   SHA**. This is *the one rule* — an agent must never test a stale pod still
   serving old code.
6. **Publishes status**: sets the Deployment to `success` with the
   `environment_url`, creates a `preview` **Check Run**, and upserts a bot comment
   with the URL. On failure it publishes a **structured failure reason** instead
   (the agent loop reads this field).

Key inputs (set in the caller's `with:`): `routing_mode` (`path`|`host`),
`ingress_host_base` (path-mode readiness base), `aws_region`, `eks_cluster`,
`ecr_repository`, `external_secret`. One required secret: `AWS_DEPLOY_ROLE_ARN`.

### `preview-teardown.yml` — destroy on close
Trigger: `pull_request` → `closed` (covers merge and close). Drops the per-PR DB
schema (best-effort), `helm uninstall`s, deletes the `pr-<N>` namespace **and
verifies it's gone**, then marks the Deployment `inactive`.

### `preview-sweep.yml` — scheduled backstop (the one that runs itself)
Trigger: `schedule` (hourly) + `workflow_dispatch`. Lists open PRs, then reaps any
`pr-*` preview namespace that no longer maps to an open PR — catching teardowns
the close event missed. This is the **only** workflow you can run directly (via
the Actions tab → *Run workflow*); it belongs in whichever repo owns the cluster's
sweep (typically the platform repo, or wherever the deploy secret lives). It reads
repo **variables** `AWS_REGION` / `EKS_CLUSTER` (defaults `us-east-1` / `pr-preview`).

### `preview-agent.yml` — the optional autonomous `@claude` loop
Trigger: `issue_comment` on a PR containing `@claude`. Gated on the commenter
having **write access** (`author_association ∈ OWNER|MEMBER|COLLABORATOR`).
Drives the SHA-gated loop and pushes fix commits, bounded by `--max-turns` +
`max_iterations`/`budget_usd`. Optional — skip it entirely for a first test. Auth
is Bedrock (OIDC) by default or the Anthropic API (`auth: api-key`). See
[`agent-loop.md`](agent-loop.md).

### `ci.yml` — the platform's own test gate (not a preview workflow)
Trigger: every `push` and `pull_request` **in the platform repo**. Runs the full
non-cluster suite + `actionlint` + `helm lint`. This is what runs when you push
*here*; it never deploys anything. See [`verification.md`](verification.md).

---

## 3. Setup — wiring GitHub to your cluster

Assumes you've already provisioned the cluster
([`runbook.md`](runbook.md) §B): CDK deployed `…Network` + `…Cicd` (VPC, ECR, and
the OIDC **deploy role**), and eksctl created the EKS Auto Mode cluster.

### Step 1 — grant the deploy role Kubernetes access ⚠️ required on the eksctl path

> **Read this even if everything "looks" set up.** On the default **eksctl** path,
> nothing grants the GitHub deploy role EKS *cluster* RBAC. The workflow will
> assume the role and reach the EKS API fine, then **every `helm`/`kubectl` call
> fails with `Unauthorized`** (surfacing as a helm/deploy failure). CDK creates
> this access entry automatically **only** on the opt-in pure-CDK cluster path
> (`clusterProvisioner=cdk`) — not on the eksctl golden path.

Run this once per cluster, after `aws eks update-kubeconfig`:

```bash
source project.env
# The CICD stack is PascalCase(PROJECT_NAME) + "Cicd" (e.g. pr-preview → PrPreviewCicd):
CICD_STACK="$(echo "$PROJECT_NAME" | awk -F- '{s="";for(i=1;i<=NF;i++)s=s toupper(substr($i,1,1)) substr($i,2);print s}')Cicd"
ROLE_ARN="$(aws cloudformation describe-stacks --stack-name "$CICD_STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='GithubDeployRoleArn'].OutputValue" \
  --output text)"

# Grant it cluster-admin via an EKS access entry (the workflow creates arbitrary
# pr-<n> namespaces and installs charts, so cluster scope is required):
aws eks create-access-entry \
  --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --principal-arn "$ROLE_ARN" --type STANDARD
aws eks associate-access-policy \
  --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --principal-arn "$ROLE_ARN" \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster
```

Equivalent with eksctl:

```bash
eksctl create iamidentitymapping --cluster "$CLUSTER_NAME" --region "$AWS_REGION" \
  --arn "$ROLE_ARN" --group system:masters --username github-deploy
```

Verify:

```bash
aws eks list-access-entries --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
  | grep -q "$ROLE_ARN" && echo "deploy role has cluster access"
```

### Step 2 — scaffold the app repo's caller workflows

From the platform repo, point the onboarder at the repo you want previewed:

```bash
source project.env
scripts/onboard-app.sh repo --repo "$GITHUB_ORG/<your-app>" [--routing path|host]
```

This writes two files into the app repo's `.github/workflows/`
(`preview.yml` + `preview-teardown.yml`) with the ALB host and ECR repo
auto-filled, and prints the exact `gh secret set …` command from step 3. The
files are thin callers — see [`examples/app-repo-caller/`](../examples/app-repo-caller/):

```yaml
# .github/workflows/preview.yml (in the APP repo)
name: preview
on:
  pull_request:
    types: [opened, synchronize, reopened]
jobs:
  preview:
    uses: <org>/<platform-repo>/.github/workflows/preview.yml@v1   # or @main until you tag a release
    permissions:
      contents: read
      deployments: write
      checks: write
      id-token: write
      pull-requests: write
    with:
      routing_mode: path
      ingress_host_base: https://<your-alb-hostname>.elb.amazonaws.com
    secrets: inherit
```

> Point `uses:` at wherever the platform repo actually lives, and pin `@<ref>` to
> a tag (`@v1`) or a commit SHA. Use `@main` only until you've tagged a release.
> The `permissions:` block is **not** optional — without `id-token: write` the
> OIDC step can't get a token, and without `deployments`/`checks`/`pull-requests`
> the status/comment steps fail.

### Step 3 — add the deploy-role secret to the app repo

```bash
gh secret set AWS_DEPLOY_ROLE_ARN --repo "$GITHUB_ORG/<your-app>" -b "$ROLE_ARN"
```

The org-wide (or allowlisted) OIDC trust already lets this repo assume the role —
no CDK change is needed to onboard another repo. If you scoped trust to specific
repos (`repoAllowlist`, the safe default), make sure this repo is in the list.

### Setup checklist

- [ ] CDK `…Network` + `…Cicd` deployed; note `GithubDeployRoleArn` + `EcrRepositoryUri`
- [ ] Cluster created (eksctl) and `kubectl get nodes` works
- [ ] `kubectl apply -f charts/preview-env/alb-ingressclass.yaml` (once per cluster)
- [ ] **Deploy role granted EKS access** (step 1) ← the easy one to miss
- [ ] App repo has `preview.yml` + `preview-teardown.yml` callers
- [ ] App repo has the `AWS_DEPLOY_ROLE_ARN` secret

---

## 4. Testing it

Three levels, cheapest first. Do #1 before touching GitHub at all.

### Level 1 — local kind (no GitHub, no AWS) — proves the deploy loop
The fastest confidence check. Bypasses Actions entirely and runs the same helm
install + SHA-gated readiness locally:

```bash
make kind-up                                       # kind + ingress-nginx, maps :8080
make preview-up PR=42 SHA=$(git rev-parse --short HEAD)
curl -s localhost:8080/pr-42/api/health | jq .     # → {"ready":true,"sha":"<pushed-sha>",...}
make preview-down PR=42
make kind-down
```

If this works, the chart + app + readiness contract are sound; anything that
then fails in CI is GitHub/AWS wiring, which narrows the search a lot.

### Level 2 — validate the workflow YAML without running it
Catch syntax/logic errors before you spend a cluster round-trip:

```bash
make test        # includes actionlint on the workflows + helm lint on the chart
```

### Level 3 — a real PR (the end-to-end test) — proves GitHub → AWS → EKS
This is what actually exercises GitHub Actions. In the **app repo** (with the
callers + secret from Setup):

1. Create a branch, make a trivial change, push, and **open a PR**.
2. Watch the **Actions** tab: the `preview` workflow runs the seven steps from
   §2. Or from the CLI:
   ```bash
   gh run watch --repo "$GITHUB_ORG/<your-app>"
   gh run view --repo "$GITHUB_ORG/<your-app>" --log            # full logs
   ```
3. On success you'll see, on the PR: a **preview environment** (Deployments), a
   green **`preview` check**, and a **bot comment** with the URL.
4. **Hit the URL** and confirm it serves *your pushed SHA*:
   ```bash
   URL="$(skills/get-pr-preview-endpoint/get-pr-preview-endpoint.sh \
           --repo "$GITHUB_ORG/<your-app>" --pr <N> --sha "$(git rev-parse HEAD)" --wait 300)"
   curl -fsS "$URL/api/health" | jq .        # 200 + your SHA, or it wouldn't have returned
   ```
   The `--sha` flag enforces the fresh-deploy invariant: it won't hand back the
   URL until the check for *that exact commit* is green.
5. **Push again** to the same PR → a new run supersedes the old (concurrency
   cancels the in-flight one) and the URL updates in place.
6. **Close/merge the PR** → `preview-teardown.yml` runs; confirm the namespace
   is gone:
   ```bash
   kubectl get ns pr-<N>        # → NotFound
   ```

> **No public DNS?** In path mode the ALB hostname works for `curl`/tests as-is.
> To open a preview in a browser, use the port-forward line the tooling prints:
> `kubectl port-forward -n pr-<N> svc/web 8<N>:80` → `http://localhost:8<N>/`.
> For host mode without a public domain, see [`host-mode.md`](host-mode.md).

---

## 5. Monitoring a run

There is **no control-plane service** — GitHub is the source of truth. A preview's
state lives in three GitHub surfaces plus two operational ones:

| Surface | Where | What it tells you |
| --- | --- | --- |
| **Deployment** | PR sidebar → *Environments* / repo → *Deployments* | `in_progress` → `success` (with `environment_url`) → `inactive` (after teardown) |
| **Check Run** (`preview`) | PR *Checks* tab | Green = ready for the pushed SHA. Red = `summary` carries the **structured failure reason** |
| **Bot comment** | The PR conversation | `🟢 Preview ready for <sha>` + the URL (upserted, not spammed) |
| **Actions logs** | Actions tab / `gh run view --log` | Step-by-step; the readiness step logs each poll + a `METRIC time_to_ready_seconds=…` line on success |
| **CloudWatch** | EKS control-plane logs (api/audit/authenticator/…) | Cluster-side auth/RBAC errors, e.g. the deploy-role `Unauthorized` from §3 |

**Resolve the current URL / diagnose from anywhere** with the droppable resolver
([`skills/get-pr-preview-endpoint/`](../skills/get-pr-preview-endpoint/)):

```bash
./get-pr-preview-endpoint.sh --pr <N>                 # print the ready URL
./get-pr-preview-endpoint.sh --pr <N> --doctor        # why is there no URL?
```

`--doctor` walks the whole chain and prints the *specific* missing link
(`not-onboarded`, `no-deployment-yet`, `awaiting-sha:<conclusion>`,
`deploy-pending:<state>`, `deployment-no-url`) instead of a bare "no deployment".

**Structured failure reasons** (from the readiness gate — the Check Run `summary`
carries one; the agent loop branches on it):

| Reason | Meaning | Where to look |
| --- | --- | --- |
| `ConfigError` | Bailed before polling (missing env/input) | The deploy step's env; caller `with:` block |
| `RoutingNotReady` | Never got a response (`000`) / no Ingress address | ALB/Ingress provisioning; `kubectl get ingress -n pr-<N>` |
| `HealthCheckFailed` | URL up but `/api/health` returned `503` | App/pod logs: `kubectl logs -n pr-<N> deploy/web` |
| `ReadinessTimeout` | Up, but never served the pushed SHA in time | Stale image/build args; wrong `basePath`; slow boot |
| `DeployFailed` | Fell over before readiness (build/helm) | The build or `helm upgrade` step logs |

**Operational health:** confirm the hourly `preview-sweep` is running clean
(Actions tab → *preview-sweep*) — a repeatedly-failing sweep means orphaned
namespaces and ALB target groups will accumulate. You can trigger it on demand
with *Run workflow* to reconcile immediately.

---

## 6. Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| **Opening a PR in the platform repo does nothing** | The preview workflows are `workflow_call` (reusable) — they don't self-trigger | Open the PR in an **app repo** that has the caller workflows, or add callers to this repo ([§1](#1-the-mental-model--two-repos), [§3](#3-setup--wiring-github-to-your-cluster)) |
| Workflow can't get AWS creds / OIDC error | Missing `id-token: write`, wrong role ARN secret, or the repo isn't in the OIDC trust scope | Add the permission block, set `AWS_DEPLOY_ROLE_ARN`, confirm the repo matches the trust `sub` claims ([`cicd-stack.ts`](../infra/lib/cicd-stack.ts)) — full walkthrough in [§6.1](#61-oidc-deep-dive-assumerolewithwebidentity-failures) |
| **`helm`/`kubectl` → `Unauthorized`** (AWS auth was fine) | Deploy role has no EKS cluster RBAC — the eksctl-path gap | Run the access-entry step ([§3 step 1](#step-1--grant-the-deploy-role-kubernetes-access--required-on-the-eksctl-path)) |
| Deploy succeeds but readiness times out (`ReadinessTimeout`) | Path-mode image built without `PREVIEW_BASE_PATH` so `/pr-N/api/health` 404s; or `/api/health` doesn't return the SHA | Ensure path-mode build args (the reusable `preview.yml` sets them); see the app contract in [`onboarding.md`](onboarding.md) |
| `RoutingNotReady` | No shared ALB / IngressClass, or Ingress has no address yet | `kubectl apply -f charts/preview-env/alb-ingressclass.yaml` once per cluster; check `kubectl get ingress -n pr-<N>` |
| Preview URL exists but a browser can't reach it | Path mode has no public DNS — the ALB host is for `curl`/tests | Use the `kubectl port-forward` line, or host mode ([`host-mode.md`](host-mode.md)) |
| `@claude` comment does nothing | Commenter lacks write access, or `preview-agent.yml` caller/secret not wired | Comment from a write-access account; wire the agent caller + Bedrock/API auth ([`agent-loop.md`](agent-loop.md)) |
| Namespaces pile up after PRs close | Teardown missed (or never wired) | Confirm `preview-teardown.yml` caller exists; the hourly `preview-sweep` is the backstop — check it's green |

### 6.1 OIDC deep-dive: `AssumeRoleWithWebIdentity` failures

The most common wiring failure is the OIDC assume-role step. The role is **a
door with a guest list**: GitHub gives each run an ID badge (an OIDC token) whose
**`sub`** claim names the run — `repo:<owner>/<repo>:pull_request` (a PR) or
`repo:<owner>/<repo>:ref:refs/heads/main` (a push to main). AWS opens the door
only if (1) it **trusts the badge issuer** — a GitHub OIDC *provider* exists in
your account — and (2) the badge's `sub` + `aud` **match the role's trust
condition**. Two distinct error messages map to those two checkpoints:

| Error text | Failed checkpoint | Cause | Check | Fix |
| --- | --- | --- | --- | --- |
| **"the web identity token … could not be validated"** | 1 — issuer / audience | No GitHub OIDC **provider** in the account, or `aud` ≠ `sts.amazonaws.com` | `aws iam list-open-id-connect-providers` | Create the `token.actions.githubusercontent.com` provider **once per account** — the CICD stack **imports** it by ARN (`cicd-stack.ts`), it does **not** create it; use the default `aud` |
| **"Not authorized to perform sts:AssumeRoleWithWebIdentity"** | 2 — the guest list | The token `sub` (`repo:<your-org>/<your-repo>:…`) isn't in the role trust's `sub` condition | the `get-role` check below | Scope the trust to your repo (below) |

Seeing #1 then #2 means you fixed the provider and are down to a `sub` mismatch.

**The one command that proves a `sub` mismatch** — run it on the role your
`AWS_DEPLOY_ROLE_ARN` secret points to:
```bash
aws iam get-role --role-name <role-name> \
  --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition'
```
The `StringLike … :sub` values are the guest list. Compare them to what your run
presents — add this debug step **before** `configure-aws-credentials`:
```yaml
- run: echo "sub = repo:${{ github.repository }}:${{ github.event_name == 'pull_request' && 'pull_request' || format('ref:{0}', github.ref) }}"
```
The printed `sub` must fall within the trust's allowed pattern. Common mismatches:

1. **Trust scoped to a different org/repo → #2.** This platform's CICD trust
   defaults to the **single** `githubOrg/githubRepo` (`infra/lib/cicd-stack.ts`);
   an app repo whose deploy role was built for a *different* repo won't match.
   **The #1 real-world case:** `githubOrg` defaults to the placeholder
   **`your-org`** and `githubRepo` to the project name (`infra/bin/infra.ts`), so
   a plain `cdk deploy` with **no `-c` flags** builds a role that trusts
   `repo:your-org/pr-preview:…` — which matches **nobody**. The role deploys
   without error, then every real run fails #2. The CDK writes **exactly two**
   subs (`:pull_request` and `:ref:refs/heads/main`) — it **never** writes a bare
   `:*`, so if `get-role` shows a `:*` sub, someone hand-edited it and the next
   `cdk deploy` **will overwrite it back to the placeholder** unless you pass the
   flags. Redeploy the CICD stack with your values — this is the durable fix:
   ```bash
   npx cdk deploy '*Cicd' \
     -c githubOrg=<your-github-owner> \
     -c githubRepo=<your-repo-name>
   ```
   Or, to trust every repo in the org, opt in with `-c trustWholeOrg=true`
   (widens to `repo:<org>/*`; convenient but broader blast radius). Then point
   `AWS_DEPLOY_ROLE_ARN` at *that* account's role.
2. **Wrong AWS account → #1 or #2.** If the role lives in a different account
   than the one you're authenticating to, deploy the CICD stack (and its OIDC
   provider) into **your** account and use its role ARN.
3. **Missing `permissions: id-token: write` → #1.** No token is minted without
   it. Confirm the caller job's `permissions` block (see [§3 step 2](#step-2--scaffold-the-app-repos-caller-workflows)).
   **Reusable-workflow trap:** these previews run via `workflow_call`, and a
   reusable workflow's permissions are **capped by the caller**. Declaring
   `id-token: write` inside `preview.yml` is *not enough* — the **caller** job
   (the `uses:` job in your app repo) must also grant it, or the token is never
   minted and you get error #1 even with a perfect trust + provider. The example
   caller sets it; a hand-written caller often forgets it.
4. **Job-level `environment:` → #2.** A job `environment: <name>` rewrites the
   `sub` to `repo:org/repo:environment:<name>`, which won't match a
   `:pull_request`/`:ref:` trust. Remove it, or add an `:environment:<name>` sub
   to the trust. (The reusable `preview.yml` uses a *Deployment* environment via
   the API, **not** a job-level `environment:`, so it's unaffected.)
5. **Overridden `aud` → #1.** The trust requires `aud = sts.amazonaws.com` (the
   `aws-actions/configure-aws-credentials` default) — don't set `audience:`.

> Security note: the safe default trusts only your one repo. `trustWholeOrg`
> (`repo:<org>/*`) trusts **every** repo in the org — fine for a single-owner
> org, riskier if untrusted users can push branches there.

#### The trust policy already looks right but it *still* fails

If `get-role` shows `aud = sts.amazonaws.com` **and** a `sub` that covers your
run (e.g. `repo:<your-org>/<your-repo>:*`) and you *still* get an error, the
`sub` is no longer the problem. Work down this list — these are the causes that
survive a correct-looking trust policy:

1. **The OIDC *provider* doesn't exist in the account (→ "could not be
   validated", not "Not authorized").** This is the #1 cause once the trust
   itself is correct. **This repo's CDK imports the provider by ARN — it never
   creates it** (`cicd-stack.ts`: `OpenIdConnectProvider.fromOpenIdConnectProviderArn`).
   If no provider exists, the role deploys fine but every assume-role fails.
   Check and create it **once per account**:
   ```bash
   aws iam list-open-id-connect-providers   # look for .../token.actions.githubusercontent.com
   # If absent, create it once (thumbprint is validated by AWS at token time):
   aws iam create-open-id-connect-provider \
     --url https://token.actions.githubusercontent.com \
     --client-id-list sts.amazonaws.com
   ```
2. **The secret points at a *different* role than the one you edited.** You may
   have fixed the trust on role A while `AWS_DEPLOY_ROLE_ARN` still points at
   role B (old deploy, wrong account, or a stale copy). Confirm the ARN in the
   secret is byte-for-byte the role whose trust you just printed — same account
   id, same `-github-deploy` name.
3. **Stale role — the redeploy didn't actually update the trust.** If the
   `cdk deploy` no-op'd (no diff) or hit a different stack, the live trust is old.
   Re-print it with `get-role` *after* the deploy and confirm your `sub` is
   present; don't trust the CDK diff alone.
4. **`git push` to a fork / different remote.** The token `sub` is the repo the
   **workflow runs in** (`github.repository`), which can differ from where you
   think you pushed. The debug `echo` step above prints the real value — compare
   it to the trust.

**Fastest triage:** add the debug `sub` echo step, run the workflow, and read
the *exact* error string. "could not be validated" → provider/aud (item 1
above). "Not authorized" with a correct-looking trust → wrong role in the secret
or a stale trust (items 2–3). The error text tells you which half to look at.

#### Minimal OIDC smoke test (isolate the handshake)

When the full `preview.yml` fails and you can't tell *why*, drop this standalone
workflow into the **app repo** (`.github/workflows/oidc-smoke.yml`), run it from
the Actions tab, and read the two outputs. It exercises **only** the OIDC
assume-role — no ECR, no helm, no cluster — so a failure here is unambiguously an
OIDC-wiring problem, and a success proves the wiring and moves the hunt
downstream (RBAC, helm, readiness).

```yaml
name: oidc-smoke
on: { workflow_dispatch: {} }
permissions:
  id-token: write          # REQUIRED — no token is minted without it
  contents: read
jobs:
  smoke:
    runs-on: ubuntu-latest
    steps:
      # 1) What sub will this run present? Must fall inside the trust's guest list.
      - run: echo "sub = repo:${{ github.repository }}:ref:${{ github.ref }}"
      # 2) The actual assume-role. Success prints the assumed-role ARN.
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_DEPLOY_ROLE_ARN }}
          aws-region: us-east-1
      - run: aws sts get-caller-identity
```

Read it like this: **step 1's `sub`** must be covered by the trust you printed
with `get-role`. If step 2 fails with *"could not be validated"* → provider/aud
(the token was rejected before the guest-list check). If it fails with *"Not
authorized"* → the `sub` from step 1 isn't in the trust, **or** the secret points
at a different role than the one you edited. If step 2 **succeeds** and prints an
ARN, OIDC is fully wired — the real fault is later in `preview.yml` (usually EKS
RBAC: the `helm`/`kubectl` `Unauthorized` case in §6, [step 1](#step-1--grant-the-deploy-role-kubernetes-access--required-on-the-eksctl-path)).

**See also:** [`runbook.md`](runbook.md) (provisioning) ·
[`onboarding.md`](onboarding.md) (the app contract + onboard/offboard) ·
[`verification.md`](verification.md) (what's proven, measured timings) ·
[`agent-loop.md`](agent-loop.md) (the `@claude` loop).
