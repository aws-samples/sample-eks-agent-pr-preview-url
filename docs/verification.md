# Verification

What is proven, and how. The bar: **all automated suites green + the full
preview loop exercised on a real cluster.** Identifiers below are placeholders —
your account id, ALB hostname, and SHAs will differ.

## Automated suites (CI-gated) — 165 checks

Run `make test` (mirrors [`.github/workflows/ci.yml`](../.github/workflows/ci.yml)):

| Suite | Count | Covers |
| --- | ---: | --- |
| bash lib | 41 | deploy + onboard/offboard helpers |
| app unit | 28 | health / runtime / logger / basic-auth of the reference workload |
| skill unit | 33 | SHA-gate decision logic + agent loop control |
| helm render | 31 | both routing modes + guardrails + protection + ESO + basic auth |
| CDK | 17 | stack assertions + cdk-nag security gate |
| native e2e | 15 | real `next build` + standalone server (simple / slow-boot / multi-commit / multi-PR) |

Plus `actionlint` (workflows) and `helm lint` (chart). All green.

## Local kind end-to-end

The full preview loop on a local kind cluster, no AWS:

```
make kind-up
make preview-up PR=42 SHA=$(git rev-parse --short HEAD)
curl -s localhost:8080/pr-42/api/health | jq .   # 200 + pushed SHA
make preview-down PR=42
```

Verified: `/api/health` returns the pushed SHA; basePath isolation (bare
`/api/health` → 404); `/pr-42/diagnostics` → 200; namespace guardrails
(ResourceQuota, LimitRange, two NetworkPolicies, PDB) applied with the
`preview.pr-preview/pr-number` label; teardown deletes the namespace. The
agent's SHA-gate decision (`decideNextAction`) was driven against the live
preview and correctly returns `ready → run_checks` for a matching SHA,
`stale → poll` for an older served SHA, and `check_failed → fix` on failure.

## Live AWS EKS (golden path, re-verified)

Provisioned end-to-end on a real EKS Auto Mode cluster and torn down:

1. **CDK** deployed `<Project>Network` + `<Project>Cicd` → real VPC (3 AZ, HA
   NAT), ECR repo `<project>/app`, and the GitHub OIDC deploy role
   `<project>-github-deploy`. Every name derived from `project_name` — verified
   in the live CloudFormation outputs.
2. **eksctl** created the EKS Auto Mode cluster from
   `eksctl/eksctl-cluster.rendered.yaml` (rendered from CDK outputs by
   `scripts/render-eksctl-config.sh`). **Auto Mode provisioned a node with no
   NodeClass surgery** — confirming the eksctl path avoids the custom-node-role
   gap of the opt-in CDK cluster path.
3. The shared **ALB** was created from the Ingress
   (`k8s-<group>-<id>.<region>.elb.amazonaws.com`), and the reference image
   (built + pushed to the real ECR) came up healthy.
4. **Host-mode routing verified with no public domain** (see
   [host-mode.md](host-mode.md)): a request carrying
   `Host: pr-1.preview.example.com` to the ALB returned `200` with the pushed
   SHA; the **commit-pinned** host `pr-1-<sha>.preview.example.com` also
   returned `200`; an unknown host `pr-999...` returned `404` (isolation — no
   cross-match).
5. **Guardrails coexist with the shared ALB on real EKS Auto Mode.** A live
   preview namespace carrying both the default-deny ingress `NetworkPolicy` and
   the egress policy still served `200` through the internet-facing ALB — the
   ALB's IP targets reach the pod from within the VPC, so the default-deny does
   not break the golden path on Auto Mode (where enforcement runs via the
   `*.networking.k8s.aws` policy-endpoint controllers). `onboard-app.sh` disables
   the policy only because it is a quick smoke-deploy that may target a
   CNI-less kind cluster; the golden-path `preview.yml` keeps it on.
6. **ABCA loop + verifiable teardown, end to end.** Autonomous cycles
   (ABCA task → PR → SHA-gated preview → screenshot on the PR →
   `abca-preview-controller.sh down` → namespace confirmed reaped) were run
   repeatedly on the live cluster; each cycle's `pr-<n>` namespace was verified
   `NotFound` after teardown, with only the intentionally-kept demo preview left
   running (see [abca-integration.md](abca-integration.md)).
7. **CloudFront front-door — 10/10 strict cycles.** With the front-door enabled
   (`CF_DOMAIN` set), a full 10-cycle batch ran **PASS=10 FAIL=0**, each cycle
   proving the *whole* chain: ABCA opened a PR → the platform deployed onto the
   **private** internal ALB → readiness via the unsigned CloudFront health
   behavior → a **signed** `*.cloudfront.net` URL emitted + screenshotted onto
   the PR → namespace reaped. Verification is provable, not assumed: the
   screenshotter **pre-verifies HTTP 200 + the pushed SHA** before posting (so an
   expired/403 signed URL can't masquerade as verified), and the batch confirms
   the posted image is a reachable real PNG. Throughout, an **unsigned** request
   returned `403`, a **signed** request `200`, and a **direct hit on the internal
   ALB from the internet timed out** (`000`) — the ALB is not internet-reachable.

### How fast is a preview testable? (measured)

Time from "start deploying this PR" to "an agent can hit a real URL that returns
the pushed SHA" — measured live on the EKS Auto Mode cluster, path mode:

| Phase | Time | Notes |
| --- | ---: | --- |
| **Warm build → testable** | **~44 s** | image layers cached; build + push + `helm upgrade --install` + pod ready + `/api/health` returns pushed SHA |
| → screenshot posted on PR | ~53 s | + ABCA-style screenshot capture/upload/comment |
| **Cold `docker build --no-cache`** | ~146 s | full `npm ci` + `next build` (ABCA PRs that touch `package.json` force this) + ~1 s push |
| Kubernetes side alone | ~30–40 s | helm install → scheduled → pod ready → SHA-gated readiness, once the image exists |
| Teardown → namespace reaped | a few s | `helm uninstall` + `kubectl delete ns` + confirmed `NotFound` |

So an agent gets a testable URL in **well under a minute on a warm build**, and
**~2.5–3 min worst case** on a cold dependency change. The dominant cost is the
container build, not Kubernetes — a build-cache or a retry-with-backoff is the
lever for making this faster/more reliable (see the roadmap).

### One contract detail worth calling out

In **path mode**, the Next.js `basePath` (`/pr-<n>`) is baked at **build time**
— so a path-mode image must be built with the `PREVIEW_ROUTING_MODE=path` and
`PREVIEW_BASE_PATH=/pr-<n>` **build args** (the reusable `preview.yml` does
this). An image built without them serves at `/` and the `/pr-<n>/api/health`
probes 404. Host mode has no such constraint (served at `/`, image reused across
PRs) — which is why host mode is the image-reuse path. See
[onboarding.md](onboarding.md) for the full app contract.

## What is not verified here

- A **publicly trusted** TLS certificate for host mode requires a public domain
  + public ACM validation (see [host-mode.md](host-mode.md)); the routing itself
  is verified above without one.
- The **autonomous CI agent** (`preview-agent.yml`) is wired to the real
  `anthropics/claude-code-action@v1` and gated/capped, but a full unattended
  `@claude` run depends on your Bedrock/API credentials — see
  [agent-loop.md](agent-loop.md).
