# Runbook

Zero to a live Preview Environment — locally on kind, and on AWS EKS. For the
"why", see [`ARCHITECTURE.md`](./ARCHITECTURE.md).

## A. Local (kind) — no AWS, no DNS

The fastest way to see the whole loop. Prereqs: Docker (with free disk), `kind`,
`kubectl`, `helm`, Node ≥ 18.

```bash
make kind-up                                   # kind cluster + ingress-nginx, maps :8080
make preview-up PR=42 SHA=$(git rev-parse --short HEAD)
curl -s localhost:8080/pr-42/api/health | jq . # -> { ready: true, sha: <SHA> }
open http://localhost:8080/pr-42/diagnostics
make preview-down PR=42
make kind-down
```

`preview-up` prints a `TIMING` line (build / deploy / ready / total ms). If
`kind load` fails with `no space left on device`, free disk — the image tarball
is staged on the host volume.

## B. AWS EKS (the real target)

Prereqs: AWS creds with admin, Node ≥ 18, `eksctl`, `kubectl`, `helm`, `aws`.
Everything below reads one config file.

### 0. Configure

```bash
# Edit the three knobs (or accept the defaults), then load them.
$EDITOR project.env         # PROJECT_NAME, GITHUB_ORG, AWS_REGION
source project.env
```

`PROJECT_NAME` (default `pr-preview`) derives every resource name; the
CloudFormation stacks are `PascalCase(PROJECT_NAME)` + `Network`/`Data`/`Cicd`
(and `Cluster` only on the opt-in CDK path). With the default that's
`PrPreviewNetwork`, `PrPreviewData`, `PrPreviewCicd`.

### 1. Provision the CDK baseline (VPC + ECR + OIDC role, optional Aurora)

CDK always owns the VPC, ECR repo, and the GitHub OIDC deploy role. The Data
stack (Aurora) is optional — include it only if you want the database path.

```bash
cd infra
npm ci
npx cdk bootstrap                              # once per account/region
# Quick-start (no DB):
npx cdk deploy PrPreviewNetwork PrPreviewCicd
# With the optional database:
npx cdk deploy PrPreviewNetwork PrPreviewData PrPreviewCicd
cd ..
```

Substitute your PascalCase stack names if you changed `PROJECT_NAME`. Note the
outputs: `GithubDeployRoleArn`, `EcrRepositoryUri`, and the VPC/subnet outputs
the eksctl renderer reads.

### 2. Create the cluster (eksctl EKS Auto Mode — the default)

The renderer fills the eksctl template from the CDK Network stack's outputs
(`VpcId`, `PrivateSubnetIds`, `PublicSubnetIds`, `AvailabilityZones`), so the
cluster reuses the CDK VPC — no second VPC.

```bash
source project.env
./scripts/render-eksctl-config.sh              # -> eksctl/eksctl-cluster.rendered.yaml
eksctl create cluster -f eksctl/eksctl-cluster.rendered.yaml
```

### 3. Connect kubectl and install the shared IngressClass

```bash
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"
kubectl get nodes                              # Auto Mode provisions nodes on demand
kubectl apply -f charts/preview-env/alb-ingressclass.yaml   # once per cluster
```

The IngressClass gives every preview Ingress a shared ALB (via ALB
`group.name`), so previews don't each spin up their own load balancer.

### 4. (Optional) Enable the database path

Skip this for the quick-start. To give previews a schema-isolated Postgres:

```bash
# a) The Data stack from step 1 must be deployed (Aurora + Secrets Manager).
# b) Install External Secrets Operator:
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace --set installCRDs=true
```

Then create a `ClusterSecretStore` named `aws-secrets-manager` (AWS provider,
your region) and grant the pod IRSA/Pod Identity with `secretsmanager:GetSecretValue`
on `$PROJECT_NAME/preview/*`. Finally set `externalSecret.enabled=true` (the
reusable workflow's `external_secret` input, or `--set` on a manual install).
ESO syncs the connection string into each `pr-<n>` namespace; the app derives
its own `pr_<n>` schema.

### 5. Onboard a repo

Org-wide OIDC trust means onboarding needs **no CDK change**. See
[`onboarding.md`](./onboarding.md) for the full contract.

```bash
source project.env
# A repo -> automatic previews on every PR (scaffolds the caller workflows):
scripts/onboard-app.sh repo --repo <org/app> [--routing path|host]
# Or deploy an existing image as a one-off preview:
scripts/onboard-app.sh image --image <ecr-ref:tag> --pr <n> [--secret <k8s-secret>]
```

The script derives the CICD stack name from `project.env`, writes the caller
workflows, and prints the `gh secret set AWS_DEPLOY_ROLE_ARN ...` command.

### 6. Open a PR → preview URL

Open a PR in the onboarded repo. The reusable workflow builds, deploys, polls
the real URL (SHA-gated), and comments the preview URL. Resolve it from any
onboarded repo with the `get-pr-preview-endpoint` skill.

## C. Opt-in: pure-CDK cluster

If you'd rather CDK own the cluster too, skip step 2 and deploy with the
provisioner flag:

```bash
cd infra
npx cdk deploy -c clusterProvisioner=cdk PrPreviewNetwork PrPreviewCluster PrPreviewCicd
cd ..
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"
```

This path uses the L1 `CfnCluster` and has a documented Auto Mode gap: the
custom node role leaves the `default` NodeClass stuck, so run the one-time fix:

```bash
source project.env
./scripts/eks-nodeclass-fix.sh                 # points the default NodeClass at the CDK instance profile
```

This is the **opt-in** path; the recommended future fix is migrating to the
`aws-eks-v2` L2 construct. The default eksctl path needs no such surgery.

## D. Host mode (optional)

Host mode addresses previews as `pr-<n>.<baseDomain>`. Two audiences:

- **Public domain:** create a Route 53 hosted zone for your base domain and a
  publicly-trusted ACM cert, then onboard with `--routing host` (or set
  `routing.mode=host`). This restores cross-PR image reuse.
- **No public domain:** you can still verify host-mode routing end to end,
  because the ALB routes on the HTTP `Host` header, not DNS. Run:

  ```bash
  ./scripts/verify-host-mode.sh <pr-number> [base-domain]
  ```

  In CI, `scripts/ci-wait-ready.sh` honors `LOCAL_VERIFY=1` to pin the host to a
  current ALB IP (`curl --resolve`) and tolerate a self-signed cert (`-k`). Only
  a publicly-trusted cert genuinely needs a public domain — see
  [`host-mode.md`](./host-mode.md).

## Teardown

```bash
# Per-PR previews are torn down on PR close by preview-teardown.yml,
# and orphans are reaped hourly by preview-sweep.yml. To remove the platform:
cd infra
npx cdk destroy PrPreviewCicd PrPreviewData PrPreviewNetwork   # + PrPreviewCluster if used
cd ..
# On the eksctl path, delete the cluster it created:
eksctl delete cluster -f eksctl/eksctl-cluster.rendered.yaml
```

## Cost notes

- The **Aurora ACU floor** (min 0.5, no scale-to-zero) is a small standing cost
  **only if you enable the optional database**. The quick-start has no DB and no
  such floor.
- **Shared ALB + single-replica previews** keep per-PR cost low — one load
  balancer for all previews, not one each.
- The **hourly sweep** reaps orphaned namespaces so abandoned PRs don't
  accumulate ALB target groups.
