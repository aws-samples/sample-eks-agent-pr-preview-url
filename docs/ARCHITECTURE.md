# Architecture

Per-pull-request **Preview Environments** on Amazon EKS — built so
an agent (or a human) can open a PR, get a fresh URL, and iterate against it
without ever testing stale code. This is the "why underneath" the quick-start:
what the pieces are, how they fit, and which decisions are load-bearing.

![AWS architecture](diagrams/aws-architecture.svg)

## The golden path, end to end

1. A pull request opens (or pushes a new commit) in an onboarded app repo.
2. The repo's caller workflow invokes the platform's reusable
   `preview.yml`, which assumes an AWS role via GitHub OIDC.
3. The workflow **builds and pushes** the app image to ECR, tagged with the
   short commit SHA. In path mode it also bakes the PR's `basePath` into the
   build, so the image is PR-specific.
4. It runs `helm upgrade --install` into a per-PR namespace (`pr-<n>`), creating
   the **Preview Environment**: one Deployment, Service, Ingress, and its
   guardrails.
5. The shared ALB (provisioned by EKS Auto Mode from the Ingress) routes the new
   preview — by URL path (`/pr-<n>/`) or by host (`pr-<n>.<baseDomain>`).
6. The workflow **polls the real URL** until `/api/health` returns `200` *and*
   its reported `sha` equals the commit just pushed — the fresh-deploy gate.
7. On success it writes a GitHub **Deployment** (`environment_url`) and a
   **Check Run** (`preview`), and upserts a PR comment with the URL. On failure
   it writes a structured failure reason to the Check Run instead.
8. An agent or human iterates: push a fix, wait for the SHA-gated preview, test.
9. On PR close/merge, teardown runs `helm uninstall` + namespace delete (and
   drops the PR's DB schema if a database was in use). An hourly sweep reaps any
   orphans.

There is **no control-plane service** anywhere in this loop. Status lives
entirely in GitHub Deployments + Check Runs + the live `/api/health`.

## Components

### The reference workload (the app)

A small Next.js app in `output: 'standalone'` mode — the thing being previewed,
not the platform itself. It exists to prove the **app contract** any workload
must satisfy (see `docs/onboarding.md`). Two parts of that contract are
structural:

- **`/api/health` SHA contract.** The endpoint returns `{ status, ready, sha }`,
  where `sha` is the `GIT_SHA` baked into the image at build time. Returns `503`
  with `ready: false` while starting, `200` when ready. This single field is
  what makes the fresh-deploy gate possible.
- **`basePath`.** In path mode the build bakes `PREVIEW_BASE_PATH=/pr-<n>` so the
  app serves correctly under its path prefix. In host mode the app serves at `/`
  and the image is reusable across PRs.

### The Helm chart — one release per PR

`charts/preview-env` renders a whole Preview Environment from a handful of
values (`prNumber`, `commitSha`, `image`, `routing.mode`, ...). One Helm release
== one PR's preview, confined to namespace `pr-<n>`. The chart ships:

- Deployment (single replica, non-root UID 1000, read-only rootfs), Service,
  and an Ingress wired to the shared ALB IngressClass.
- **Per-PR guardrails**: a ResourceQuota, LimitRange, default-deny NetworkPolicy
  (egress limited to DNS + the shared DB port), and a PodDisruptionBudget — so a
  runaway PR can't starve the cluster or reach what it shouldn't.
- An optional `ExternalSecret` (off by default) for the database path.

### The GitHub Actions deploy engine

`.github/workflows/preview.yml` is the deploy engine — reusable, called by a
~5-line caller in each app repo. It builds, pushes, `helm`-installs, polls for
readiness, and publishes status. `preview-teardown.yml` handles PR close.
`preview-sweep.yml` runs hourly to reconcile namespaces against open PRs.

Deliberately, **there is no controller and no platform-owned datastore**. The
"API" of the platform is GitHub's own primitives:

- **GitHub Deployment** (`preview/pr-<n>`) carries the `environment_url`.
- **Check Run** (`preview`) carries success/failure + a structured failure
  reason the agent reads.
- **`/api/health`** is queried live for the authoritative running SHA.

### CDK infrastructure

`infra/` (CDK, TypeScript) **always** owns the durable AWS baseline: the VPC
(HA NAT, ELB-tagged subnets), Aurora Serverless v2 (the optional Data stack),
the ECR repository, and the GitHub **OIDC deploy role**. The OIDC trust is
**org-wide** (`repo:<org>/*`), which is why onboarding a new repo needs no CDK
change. Stacks are cdk-nag-checked.

### The cluster and the shared ALB

The cluster runs **EKS Auto Mode**: managed compute that provisions nodes on
demand and, critically, provisions **ALBs directly from Ingress objects**. A
single shared IngressClass (`charts/preview-env/alb-ingressclass.yaml`, applied
once) uses an ALB `group.name` so *every* preview Ingress lands on **one shared
ALB** — not one ALB per PR. That is the routing substrate the whole model rests
on.

The default provisioner is **eksctl** (see Key decisions). The cluster reuses
the CDK-provisioned VPC by subnet id, so there's exactly one VPC.

### Isolation and guardrails

Previews are **compute-isolated** by namespace and bounded by the chart's
guardrails. When the optional database is enabled, they are additionally
**schema-isolated**: each PR's data lives in its own `pr_<n>` Postgres schema in
the shared cluster, so PR #42 cannot read or clobber PR #51's rows.

### Optional database: Aurora + ESO + schema isolation

The database is **off by default** — the quick-start needs none (the chart ships
`externalSecret.enabled=false`, `databaseUrlInline=""`). The opt-in path:

1. Deploy the CDK **Data stack** (Aurora Serverless v2; creds land in Secrets
   Manager under `$PROJECT_NAME/preview/database`).
2. Install **External Secrets Operator** and a `ClusterSecretStore` named
   `aws-secrets-manager`, plus IRSA granting `secretsmanager:GetSecretValue`.
3. Set `externalSecret.enabled=true`. ESO syncs the connection string into each
   `pr-<n>` namespace; the app derives its `pr_<n>` schema at runtime.

### The two agent paths

- **Local interactive loop (the hero).** `skills/preview-iterate` drives
  edit → push → wait-for-SHA-gated-preview → test, locally and interactively.
- **Autonomous CI loop.** `.github/workflows/preview-agent.yml` wires
  `anthropics/claude-code-action@v1` to the same loop, triggered by `@claude`
  on a PR, bounded by iteration and budget caps.

Both are detailed in `docs/agent-loop.md`.

![Agent flow](diagrams/agent-flow.svg)

## The SHA-gate invariant (why it matters for agents)

The preview URL is **reused** across pushes: after a fix is pushed, the old pod
may still be serving old code at the same URL for a while. An agent that curls
the URL naively will "verify" stale code and draw the wrong conclusion.

The invariant, enforced at every gate, is: **never test a deployment whose SHA
isn't the SHA you pushed.** Concretely, a preview is safe to test only when
*both* hold for the pushed commit:

1. the `preview` Check Run for that SHA has `conclusion: success`, and
2. `GET <url>/api/health` returns `{ ready: true, sha: <pushed SHA> }`.

The deploy workflow's readiness gate (`scripts/ci-wait-ready.sh`) enforces this
before it ever reports success; the skills enforce it before they run checks.
For an autonomous agent this is the difference between a reliable loop and one
that chases ghosts.

## The config-derivation model

There is **one config file** at the repo root: `project.env`, with three knobs.

| Knob | Default | Derives |
| --- | --- | --- |
| `PROJECT_NAME` | `pr-preview` | cluster name, ECR repo (`$PROJECT_NAME/app`), IAM deploy role (`$PROJECT_NAME-github-deploy`), node instance profile (`$PROJECT_NAME-nodes`), Secrets Manager prefix (`$PROJECT_NAME/preview`), CloudFormation stack prefix |
| `GITHUB_ORG` | `your-org` | the org whose repos may assume the deploy role (OIDC) |
| `AWS_REGION` | `us-east-1` | the region everything is provisioned in |

CloudFormation stack ids are `PascalCase(PROJECT_NAME) + {Network,Cluster,Data,
Cicd}` — with the default, `PrPreviewNetwork`, `PrPreviewData`, `PrPreviewCicd`
(and `PrPreviewCluster` only on the opt-in CDK path). The one name that is a
**fixed constant, not derived**, is the Kubernetes label domain
`preview.pr-preview/*` — the sweep and teardown select on it, so it stays stable
regardless of `PROJECT_NAME`.

Scripts `source project.env`; CDK reads `PROJECT_NAME` (or `-c projectName=`);
the eksctl renderer fills its template from the same canonical set. Change the
knob, and every resource name follows.

## Key decisions

- **GitHub Actions is the engine, not a controller.** Status is GitHub
  Deployments + Check Runs + live `/api/health`. No control-plane service, no
  platform-owned datastore, nothing to run or keep alive between deploys.
- **eksctl is the default; CDK cluster is opt-in.** eksctl EKS Auto Mode is the
  proven cluster path; CDK always owns VPC + Aurora + ECR + OIDC. The pure-CDK
  cluster (`cdk deploy -c clusterProvisioner=cdk`) is available but has a
  documented Auto Mode custom-node-role gap (needs `scripts/eks-nodeclass-fix.sh`);
  the recommended future fix is migrating to the `aws-eks-v2` L2 construct.
- **The database is optional.** The quick-start runs with no DB. Turn it on for
  per-PR schema-isolated Postgres.
- **Two routing modes.** `path` (default, no DNS: `<alb>/pr-<n>/`, basePath
  baked) and `host` (`pr-<n>.<baseDomain>`, image reuse, needs Route53 + a
  public ACM cert). Host mode is verifiable with no public domain — see
  `docs/host-mode.md`.
- **Agent-first.** The SHA-gate invariant and the structured failure reasons
  exist so an agent can drive the loop reliably, not just a human.
