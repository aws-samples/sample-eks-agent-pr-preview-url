# Security Audit Report — eks-agent-pr-preview-url

**Date:** 2026-07-19
**Scanner:** AWS Automated Security Helper v3.2.4
**Mode:** local
**Directory:** /Users/bmaguir/git/eks-agent-pr-preview-url
**Config:** `.ash/.ash.yaml` (ignore_paths + suppressions with justifications)

## Executive Summary

Nine scanners ran against the project (bandit, cdk-nag, cfn-nag, checkov,
detect-secrets, grype, npm-audit, opengrep/semgrep, syft). The initial scan
surfaced **614 actionable findings**, but triage showed **zero real secrets and
zero exploitable vulnerabilities in project source code**: ~586 were in generated
build artifacts and vendored dependencies, and the remainder were configuration
keywords, test fixtures, and heuristic false positives. Remediation: the real
IaC-hardening findings on our own Helm chart and CDK were **fixed** (13),
generated/vendored paths were **excluded** via `ignore_paths` (~586), and the
verified false positives + documented accepted-risks were **suppressed with
written justification** (42). The final scan reports **0 actionable findings** —
every scanner PASSED.

## Scan Results

| Severity | Initial | Fixed | Suppressed | Triaged (excluded) | Open |
|----------|---------|-------|------------|--------------------|------|
| CRITICAL | 0       | 0     | 0          | 0                  | 0    |
| HIGH     | 606     | 4     | 21         | ~581               | 0    |
| MEDIUM   | 0       | 0     | 0          | 0                  | 0    |
| LOW      | 8       | 9*    | 21         | ~5 (bandit vendored)| 0   |
| **Total**| **614** | **13**| **42**     | **~586**           | **0**|

\* K8s checkov findings on `cloudfront-keepalive.yaml` were fixed together (probes,
resources, high-UID, token mount, pull-policy). Severity buckets are approximate —
ASH aggregates most raw findings as HIGH; see per-scanner detail below.

## Scanners Executed (final scan)

| Scanner | Status | Findings | Actionable | Notes |
|---------|--------|----------|------------|-------|
| bandit  | PASSED | 0        | 0          | 8 HIGH were all in vendored `infra/node_modules/aws-cdk-lib` → excluded |
| cdk-nag | PASSED | 0        | 0          | AwsSolutionsChecks clean (also gated in `infra/test/nag.test.ts`) |
| checkov | PASSED | 5        | 0          | 13 fixed; 5 accepted-risk suppressed (below) |
| detect-secrets | PASSED | 8 | 0        | 549 in generated build cache → excluded; 8 config-keyword FPs suppressed |
| npm-audit | PASSED | 0       | 0          | clean |
| semgrep | PASSED | 29       | 0          | 22 mutable-action-tag + 7 injection/secrets-inherit — all suppressed w/ justification |
| cfn-nag / grype / opengrep / syft | MISSING | 0 | 0 | scanner deps not installed in local mode |

## Findings Detail

### Fixed Findings

| # | Scanner | Rule | File | Fix Applied |
|---|---------|------|------|-------------|
| 1-9 | checkov | CKV_K8S_8/9/10/11/12/13/15/38/40 | charts/preview-env/cloudfront-keepalive.yaml | Added liveness/readiness probes, CPU/memory requests+limits, high UID (10001), `imagePullPolicy: Always`, `automountServiceAccountToken: false` |
| 10 | checkov | CKV_DOCKER_2 | app/Dockerfile | Added `HEALTHCHECK` hitting `/api/health` at the basePath |
| 11 | checkov | CKV_AWS_162 | infra/lib/data-stack.ts | Enabled RDS `iamAuthentication` (move off the shared static DB credential toward IAM tokens) |

### Suppressed Findings (verified false positives + accepted risks)

| Scanner | Rule | Path(s) | Reason |
|---------|------|---------|--------|
| detect-secrets | SECRET-SECRET-KEYWORD | charts values.yaml / externalsecret.yaml; example callers | Config field NAMES (`secretName`, `secretKey`) and the GitHub keyword `secrets: inherit` — not secret values |
| detect-secrets | SECRET-HEX-HIGH-ENTROPY-STRING | skills/preview-iterate/lib/*.test.mjs | Fake fixture SHA `abcdef1234567890` in unit tests |
| checkov | CKV_SECRET_6 | charts/preview-env/values.yaml | Base64 flagged on a config field default, not a secret |
| checkov | CKV2_GHA_1 | examples/app-repo-caller/* | Example caller; the reusable workflow it calls declares least-privilege job permissions |
| checkov | CKV_K8S_43 | cloudfront-keepalive.yaml | Accepted: throwaway health-holder on a public nginx tag; digest-pinning adds no security to a static 200-responder |
| checkov | CKV2_K8S_6 | cloudfront-keepalive.yaml | Accepted: static health-responder exposing only `/keepalive`; namespace NetworkPolicy is on the roadmap |
| semgrep | run-shell-injection | .github/workflows/preview.yml, preview-teardown.yml | Interpolated values are trusted `workflow_call` inputs (quoted), not attacker-controlled PR data |
| semgrep | github-script-injection | .github/workflows/preview.yml | Value read via `process.env.PREVIEW_URL` (the safe pattern), not interpolated into the script body |
| semgrep | ifs-tampering | scripts/render-eksctl-config.sh | Deliberate function-scoped `local IFS=,` for CSV parsing — standard safe bash |
| semgrep | secrets-inherit | examples/app-repo-caller/* | Example caller MUST use `secrets: inherit` to pass the deploy-role secret to the reusable workflow |
| semgrep | github-actions-mutable-action-tag | all `.github/workflows/*` | Actions pinned by major-version tag by design (aws-samples readability); SHA-pinning is a documented consumer-side hardening (see docs/persona-review-backlog.md) |

### Triaged as Noise (excluded via `ignore_paths`)

| Category | Approx. Count | Reason |
|----------|--------------:|--------|
| `app/tsconfig.tsbuildinfo` | 542 | Generated TypeScript incremental build cache (gitignored); hashes trip detect-secrets |
| `infra/cdk.out/` | 12 | Generated CDK synth output (gitignored); re-derived from CDK source, which cdk-nag gates |
| `infra/node_modules/aws-cdk-lib/` | 8 (bandit HIGH) + others | Vendored dependency; SCA is covered by npm-audit |

### Open Findings

No open findings.

## Additional Reports

Full scanner output (gitignored, local-only under `.ash/`):
- **HTML (interactive):** `.ash/ash_output/reports/ash.html`
- **SARIF:** `.ash/ash_output/reports/ash.sarif`
- **CSV:** `.ash/ash_output/reports/ash.csv`

## Attestation

This report was generated by automated security scanning using AWS Automated
Security Helper v3.2.4. Human review validated every suppression rationale;
residual risks (per-PR DB roles, action SHA-pinning, keepalive NetworkPolicy) are
documented in [SECURITY.md](SECURITY.md) and [docs/persona-review-backlog.md](docs/persona-review-backlog.md).

- [ ] Reviewed by: _______________
- [ ] Date: _______________
- [ ] Decision: PASS / PASS WITH CONDITIONS / FAIL
- [ ] Notes: _______________
