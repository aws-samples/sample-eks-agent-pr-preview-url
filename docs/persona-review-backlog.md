<!-- Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved. -->
<!-- SPDX-License-Identifier: MIT-0 -->
# Persona review — remaining LOW-priority backlog

Three personas (novice DevOps ~EKS-100, platform engineer ~EKS-200, senior
platform/security ~EKS-300) assessed the project. **All HIGH and MEDIUM findings
were addressed** (see the git history and [next-steps.md](next-steps.md) /
[SECURITY.md](../SECURITY.md)). The LOW-priority items below are intentionally
deferred — polish and defense-in-depth, not adoption blockers.

## Setup / onboarding (Priya, EKS-100)
- **`make install` always installs `infra/` (CDK) deps** even for the kind-only
  path. A `make install-local` split would save a local-only user a full CDK install.
- **README quick-start hardcodes `PrPreviewNetwork PrPreviewCicd` stack names.**
  These derive from `PascalCase(PROJECT_NAME)`; a one-line caveat (as the runbook
  has) would prevent a mismatch for someone who renamed `PROJECT_NAME`.
- **`eksctl/` ships `eksctl-cluster.yaml` (template) + `.rendered.yaml` (gitignored)**;
  a one-line header comment in the template would explain the pair.

## Test / release hygiene (Marcus, EKS-200)
- **CI doesn't invoke `db-isolation.mjs` or `scripts/test-all.sh`** — it lists the
  suites individually. The DB test's skip-guard is only exercised locally. Wiring a
  DB-backed job (service container) would actually run the isolation proof.
- **No published `v1` tag yet.** The release process is documented
  ([CONTRIBUTING.md](../CONTRIBUTING.md) → *Cutting a release*) but the tag, a real
  CHANGELOG version, and a Chart.yaml bump off `0.1.0` still need to be cut on release.
  The `preview-teardown.yml` caller example still pins `@v1` without the `@main`
  fallback note its sibling has.
- **Chart `maintainers`/`sources` are stubs** and there's no `.helmignore` — would
  fail a strict internal chart-repo lint.

## Security defense-in-depth (Dana, EKS-300) — honestly documented, deferred by design
- **Shared-DB single trust domain.** Per-PR DB *roles* (not one shared user) or
  per-PR databases are the real cross-tenant boundary — roadmap. Documented in
  [SECURITY.md](../SECURITY.md) so nothing overclaims today.
- **CI deploy-role RBAC is cluster-admin when CDK owns the cluster.** Narrow to
  `pr-*` namespaces for multi-team use (eksctl path avoids this by default).
- **`dbEgressCidr` defaults to `0.0.0.0/0`** (no-regression default). Secure-by-default
  would ship the VPC CIDR; the knob exists.
- **`/pr-*/api/health` is unauthenticated** and returns build SHA + PR number (a
  mild enumeration oracle even behind the signed front door). Minimizing its body is
  a possible hardening.
- **`ci-wait-ready.sh` failure classifier is still tested via an inline paraphrase**
  (the reaper + signer paraphrases were replaced with real behavioral tests; this
  lower-consequence one remains). Extracting it into a sourceable function + testing
  the real code would close the last paraphrase gap.
- **Constant-time compare / hashed credential for basic auth** — acceptable for the
  stated low-value-wall posture; noted so it isn't mistaken for real protection.

## Observability / enterprise (roadmap — see [roadmap-production.md](roadmap-production.md))
- No Prometheus/OTel/centralized logging/alerting; no alarm on the CloudFront
  keepalive or on the internal-ALB ARN changing.
- No global concurrent-preview cap or cost alerting; Aurora Serverless v2 floors at
  0.5 ACU (no scale-to-zero).
- No DB backup/PITR (Aurora `removalPolicy: DESTROY`); no signing-key rotation/backup.
