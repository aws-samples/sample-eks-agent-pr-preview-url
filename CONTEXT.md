# Domain model & glossary

The ubiquitous language for this project — instant per-pull-request
**Preview Environments** on Amazon EKS, driven agent-first, with a Next.js app
as the reference workload. Use these terms precisely; the "avoid" notes flag the
ambiguities that bit us.

## Language

**Preview Environment**:
The isolated, ephemeral deployment of a single PR's code, reachable at its own
URL, created when the PR opens and destroyed when it closes/merges.
_Avoid_: "preview deployment" (a hosted-PaaS term for the artifact), "staging" (that's shared and long-lived).

**Reference Workload**:
The example application the platform deploys — a Next.js app in `output: 'standalone'` mode. The thing being previewed, not the platform itself. Contract: its `/api/health` returns the build `GIT_SHA` and it respects `basePath`.
_Avoid_: "the app" (ambiguous — platform vs. workload).

**Golden Path**:
The single, fully-supported end-to-end flow: open PR → build → deploy to a Preview Environment → URL posted back → iterate → teardown on merge.

**Deploy Workflow**:
The GitHub Actions workflow that builds the image and runs `helm upgrade --install` to create/update a Preview Environment. The deploy engine; there is no control-plane service.
_Avoid_: "controller", "control plane" (we chose not to build one).

**Preview Status**:
The machine-readable state of a Preview Environment, surfaced as a GitHub **Deployment** (`environment_url`) + **Check Run** (`output.summary` carries status + a structured failure reason). This is what the Preview Skill reads.
_Avoid_: "the API", "MCP endpoint" (there is no platform-owned API).

**Preview Skill**:
The Claude Code skill that drives the agent loop: open/update PR → poll **Preview Status** until ready (SHA-gated) → curl the preview → on failure read the structured reason, fix, push → re-check. `preview-iterate` is the **interactive** (human-invoked, local) hero; an **autonomous** GitHub Actions agent (`preview-agent.yml`) drives the same loop within hard caps.
_Avoid_: "the bot" (that's the URL-commenting workflow step, a separate concern).

**Routing Mode**:
The config switch (`routing.mode`) selecting how a Preview Environment is addressed on the shared ALB. Two supported modes — **`path`** (`<alb>/pr-<n>/`, `basePath` baked, no DNS needed, no cross-PR image reuse) and **`host`** (`pr-<n>.<baseDomain>`, app at `/`, image reuse kept; needs Route 53 + a public ACM cert for a browser, though routing is verifiable with no domain). `path` is the default; `host` is opt-in.

**Preview Path**:
The `/pr-<n>/` URL prefix used in **`path`** Routing Mode, baked into the Next.js build as `basePath` (so the image is PR-specific). Not used in `host` mode.
_Avoid_: assuming it always applies — it's mode-specific.

**Preview Host**:
The `pr-<n>.<baseDomain>` hostname used in **`host`** Routing Mode. The image-reuse-preserving address.
_Avoid_: assuming a public domain exists — routing works without one; only a publicly-trusted cert needs it.

**SHA Gate** (fresh-deploy invariant):
The rule that a Preview Environment is only safe to test when, for the pushed commit, **both** the `preview` Check Run is `success` **and** `/api/health` reports that same `sha`. Because the preview URL is reused across pushes, this is what stops an agent from "verifying" stale code.

**Teardown**:
Removal of a Preview Environment. Primary trigger: the PR closing/merging (`helm uninstall` + namespace delete, and — if the DB is enabled — dropping the PR's schema). Backstop: a scheduled sweep that reconciles namespace labels against open PRs.
_Avoid_: "cleanup" (too vague).

**Preview Scope**:
The set of config + credentials a Preview Environment runs with. Non-secret values come from Helm; when the optional database is enabled, secrets are synced from AWS Secrets Manager via External Secrets Operator. Preview-scoped creds point at the **shared sandbox backend**, distinct from Production creds.
_Avoid_: "preview secrets" alone (it's scope = config + creds together).

**Shared Sandbox Backend**:
The **optional** single **Amazon Aurora Serverless v2 (PostgreSQL)** cluster that all Preview Environments talk to when the database path is enabled. Previews are **compute-isolated and schema-isolated** — they share one cluster but each PR confines its data to its own `pr_<n>` Postgres schema. Part of the long-lived baseline, not torn down per PR. Off by default: the quick-start needs no database.
_Avoid_: implying it's always present (it's opt-in); implying a per-PR *database/cluster* (still one shared cluster).

## Cluster provisioning

**eksctl (default)**: EKS Auto Mode cluster provisioned by eksctl, reusing the CDK-provisioned VPC by subnet id. The proven path — Auto Mode's node role works with no NodeClass surgery.
**CDK cluster (opt-in)**: `cdk deploy -c clusterProvisioner=cdk` — CDK owns the cluster too, at the cost of a documented Auto Mode custom-node-role gap (needs `scripts/eks-nodeclass-fix.sh`).
In both cases CDK always owns the VPC + Aurora + ECR + the OIDC deploy role.

## Relationships

- A **Pull Request** maps to exactly one **Preview Environment**.
- A **Preview Environment** runs one **Reference Workload**, addressed by its **Preview Host** (`host` mode) or **Preview Path** (`path` mode) per the **Routing Mode**.
- All **Preview Environments** share one ALB (via EKS Auto Mode).
- When the database is enabled, all **Preview Environments** share one **Shared Sandbox Backend** (compute-isolated, schema-isolated per `pr_<n>`).
- A **Preview Environment** loads its **Preview Scope** (Helm config + optional ESO-synced secrets).

## Example dialogue

> **Dev:** "When the author pushes a fix to a PR, does the **Preview Skill** just
> re-curl the **Preview Path**?"
> **Domain expert:** "Not immediately — that URL is reused, so it might still be
> serving the old build. The skill waits for the **Check Run** on the *new* head
> SHA to go green *and* for `/api/health` to report that same `sha` — the **SHA
> Gate** — then it curls. Otherwise it'd 'verify' stale code."
> **Dev:** "And the data it sees?"
> **Domain expert:** "Depends. The database is optional. With it on, previews are
> compute-isolated but they all hit the one **Shared Sandbox Backend** (Aurora
> Serverless v2) with **Preview Scope** creds — each in its own `pr_<n>` schema.
> No per-PR database. Off, and there's no DB at all."

## Resolved ambiguities

- **preview URL scheme** — **two Routing Modes**, not one. `path` (ALB path +
  basePath, no DNS, the default) and `host` (subdomain, image reuse, opt-in).
- **isolation** was used to mean both compute and data — previews are
  **compute-isolated** always, and **schema-isolated** (each PR's data in its own
  `pr_<n>` Postgres schema in the shared cluster) when the optional DB is on.
- **cluster provisioning** — **eksctl EKS Auto Mode is the default**; the
  pure-CDK cluster is opt-in with a documented node-role gap.
