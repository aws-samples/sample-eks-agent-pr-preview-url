# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added — preview test-task (verify the preview, not just screenshot it)

- **Second, test-only task** that runs test cases against the live preview URL and
  posts a clean **pass/fail** comment on the PR — closing the loop from "the preview
  rendered" to "the change works." Opens no PR, pushes nothing (read-only).
  ([docs/abca-integration.md](docs/abca-integration.md#the-test-task-loop--verify-the-preview-not-just-screenshot-it))
  - **Trigger:** the deploy path (opt-in `TEST_TASK=1`) POSTs a `CreateTaskRequest`
    to ABCA's HMAC webhook `POST /v1/webhooks/tasks` naming the `coding/test-preview-v1`
    workflow (`pr_number` structured, preview URL in `task_description`). **Idempotent
    on (PR, SHA)** — a re-deploy of the same SHA never re-tests. Unset = unchanged.
  - **Test-task workflow** (`abca/workflows/test-preview-v1.yaml`): a trimmed fork of
    ABCA's read-only `coding/pr-review-v1` (`ensure_pr strategy: resolve` opens no PR).
    Asserts: signed page 200 (expired signature ⇒ *inconclusive*, never a false pass),
    `/api/health` `ready` + **SHA fresh-deploy gate**, routing `prNumber`, page renders,
    and the **actual change is live**.
  - **Two paths, same loop** (mirrors the screenshot split): the ABCA-native fork, or a
    local runner (`scripts/demo/test-preview.sh`) for environments where ABCA's CDK can't
    be redeployed. Submit helper `abca-submit-test-task.sh`; e2e harness
    `test-task-e2e-batch.sh` (deploy → trigger → test → assert verdict, N consecutive).
  - **Escalating rigor** (`TEST_TIER=1..4`): tier 1 contract (SHA-gate, routing, change
    live); tier 2 depth (basePath/routingMode echo, full health contract); tier 3 security
    posture (unsigned page → **403**, gate enforced); tier 4 adversarial (tampered
    signature → **403**, cross-PR isolation). The batch ramps tier across cycles and passes
    only on zero failures **and** ≥`MIN_CONSEC` (default 3) consecutive clean cycles.
  - **Robustness hardening** (surfaced by the escalating batch): the controller validates
    the PR head SHA is hex and retries on a transient `gh`/API error (a rate-limit JSON was
    being used verbatim as the SHA, poisoning the build); the runner treats an ALB/CDN
    **origin-error page returned as HTTP 200** as *inconclusive* (transient pod-unavailable),
    not a content failure; and the e2e harness **polls** for the result comment (GitHub's
    comments API is eventually consistent). Shared GitHub-API access is centralized in
    `scripts/demo/gh-lib.sh` (`pr_head_sha`, `pr_title` — shape-validated + retried) so
    every caller is hardened, not just one.
  - **Honesty guardrails** (from code review): a missing expected-change text yields an
    explicit ⚠️ "change unverified" note rather than a silent full pass; test-task
    idempotency is **verdict-scoped** so an *inconclusive* never blocks the re-run that
    would produce a real verdict.

### Added — CloudFront front-door (opt-in, stronger than basic auth)

- **Signed-URL access over a private ALB** ([docs/design-cloudfront-frontdoor.md](docs/design-cloudfront-frontdoor.md)):
  an opt-in CloudFront distribution reaches an **internal-scheme** ALB via a
  **VPC Origin** (http-only, so no self-signed cert), gated by **short-TTL signed
  URLs** — no static password, trusted TLS on `*.cloudfront.net`, no public domain.
  The ALB is not internet-reachable. A `/pr-*/api/health` behavior stays unsigned so
  the readiness gate works. Ships `cf-sign-url.sh` (dependency-free openssl signer;
  key in Secrets Manager) and an `alb-internal` IngressClass. Enabled per the
  controller's `CF_DOMAIN`; the legacy public-ALB + basic-auth path is unchanged when
  unset. Verified live: unsigned → 403, signed → 200, direct ALB → unreachable.

### Added — ABCA integration + optional preview auth

- **Optional HTTP Basic Auth** for previews (`basicAuth.enabled`, `BASIC_AUTH_B64`)
  enforced in the app (Next.js middleware); `/api/health` is exempt so the
  readiness gate keeps working. Public-by-default preserved. Unit- + render-tested.
- **ABCA integration** (`docs/abca-integration.md`, `scripts/demo/`): pair the
  platform with [Autonomous Background Coding Agents](https://github.com/aws-samples/sample-autonomous-cloud-coding-agents)
  — ABCA opens a PR, the platform deploys its preview and emits the
  `deployment_status` ABCA screenshots back onto the PR. Includes a demo
  controller, task submitter, screenshot poster, batch runner, and an
  end-to-end flow diagram. Verified over 10 autonomous cycles.
- **Verifiable demo teardown.** `abca-preview-controller.sh down <N>` uninstalls
  the release, deletes the `pr-<N>` namespace, marks the GitHub Deployment
  inactive, and polls until the namespace is confirmed reaped. The e2e batch
  tears down each cycle (`TEARDOWN=1`), keeps the last preview live
  (`KEEP_LAST=1`), and reports any orphaned `pr-*` namespaces.

### Added — initial open-source release

- **Agent-first PR preview environments on Amazon EKS.** A coding agent (or a
  human) opens a PR, the platform builds and deploys an isolated Preview
  Environment at its own URL, and the `preview-iterate` skill drives an
  SHA-gated test loop against the live URL — so an agent never tests stale code.
- **One-file configuration** (`project.env`): `project_name`, `github_org`,
  `aws_region` derive every AWS/Kubernetes resource name (cluster, ECR repo,
  IAM deploy role, node instance profile, Secrets Manager path, k8s label
  domain, ALB group, CloudFormation stack ids).
- **Two cluster-provisioning paths:** eksctl EKS Auto Mode (default, proven;
  shipped `eksctl/eksctl-cluster.yaml` + `scripts/render-eksctl-config.sh`
  that fills it from CDK outputs), and an opt-in pure-CDK path
  (`-c clusterProvisioner=cdk`).
- **Database is optional.** The default quick-start needs no database; Aurora
  Serverless v2 with per-PR schema isolation is an opt-in "with data" path via
  External Secrets Operator.
- **Autonomous CI agent** (`preview-agent.yml`) wired to
  `anthropics/claude-code-action@v1`, defaulting to Amazon Bedrock (OIDC) with a
  direct Anthropic API variant, inside a same-repo + `@claude` guard and
  iteration/cost caps.
- **Both routing modes:** path (default, no DNS) and host
  (`pr-<n>.<domain>`), with `scripts/verify-host-mode.sh` proving host-mode
  routing with no public domain via the ALB Host header.
- **Namespace guardrails** (ResourceQuota / LimitRange / default-deny
  NetworkPolicy / PDB), reliable teardown on PR close plus a scheduled sweep,
  and optional ALB-OIDC access protection.
- **Architecture diagrams** (`docs/diagrams/`): AWS services architecture and
  the end-to-end agent-PR-to-testable-URL flow.
- **aws-samples project meta:** MIT-0 `LICENSE`, `NOTICE.txt`,
  `CODE_OF_CONDUCT.md`, `CONTRIBUTING.md`.
