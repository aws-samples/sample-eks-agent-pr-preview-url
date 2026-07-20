# CloudFront front-door — signed URLs over a private ALB

> Status: **built and verified** on EKS Auto Mode. This is the stronger-than-basic-auth
> access model charted in the *CloudFront front-door* wayfinder map and implemented
> as an **opt-in** layer over the default public-ALB path.

## Why

The default demo serves previews on an **internet-facing** ALB with a self-signed
cert and app-layer HTTP basic auth — a deliberately low-value convenience wall. This
front-door replaces that with:

- a **private** (internal-scheme) ALB that is **not reachable from the internet**;
- **short-TTL CloudFront signed URLs** as the access gate (no static password);
- **trusted TLS on `*.cloudfront.net`** with **no public domain** required;
- deletion of the two local ABCA browser patches — a signed URL navigates natively
  (no header injection, no self-signed-cert workaround).

## Request path

```
Agent ── signed https://<dist>.cloudfront.net/pr-N/?Expires=…&Signature=…&Key-Pair-Id=…
      ─▶ CloudFront (verifies signature; trusted TLS)
         ─▶ VPC Origin (http-only)
            ─▶ internal ALB (scheme:internal, private subnets)
               ─▶ EKS Ingress /pr-N ─▶ preview pod
```

The internet cannot reach the ALB directly (verified: an external request to the
internal ALB hostname times out). CloudFront is the only public hop.

## What was built (live)

| Piece | Detail |
| --- | --- |
| Internal ALB | opt-in `alb-internal` IngressClass (`charts/preview-env/alb-ingressclass.yaml`), `scheme: internal`, own group `pr-preview-internal`, in the CDK VPC's `internal-elb` private subnets |
| VPC Origin | `aws cloudfront create-vpc-origin` against the internal ALB ARN, `http-only` origin (removes the self-signed cert entirely) |
| Distribution | default behavior **signed** (trusted key group); a `/pr-*/api/health` behavior **unsigned** so the readiness gate + probes work without a signature; `CachingDisabled`; `AllViewer` origin request policy |
| Signing key | RSA-2048 key pair; public key + key group in CloudFront; **private key + keyPairId in Secrets Manager** (`pr-preview/cloudfront-signing-key`) — never on disk or in CI logs |
| Signer | `scripts/demo/cf-sign-url.sh` — dependency-free (openssl) canned-policy signer; short TTL (default 30 min), self-expiring |

## Key decisions (resolved from the wayfinder map)

- **Domainless-first.** Path routing `/pr-N` on `*.cloudfront.net`; per-PR hostname
  routing remains a documented upgrade for when a public domain exists.
- **Readiness under a signed origin.** The gate polls the **unsigned** `/pr-*/api/health`
  CloudFront behavior; k8s readiness/liveness probes hit the pod directly (unaffected).
- **Who signs / TTL.** The deploy controller mints the signed URL **on demand** at
  deploy time with a 30-min TTL and emits it as `environment_url`. Long-lived previews
  are re-signed on demand rather than baking a long TTL.
- **Revocation.** CloudFront has **no per-URL revocation** — effective early revocation
  is short TTL + tearing down the route/namespace. Key rotation is the broad hammer.
- **Auto Mode adaptation.** EKS Auto Mode's `IngressClassParams` has **no `securityGroups`
  field** (unlike standalone LBC), so the "SG-locked to the CloudFront prefix list"
  guard from the research isn't available; instead the ALB is `scheme:internal`
  (private, not internet-reachable) and `inboundCIDRs` can restrict to the CloudFront
  origin-facing prefix-list ranges.

## Using it

```bash
# with CF_DOMAIN set (see project.local.env), the controller uses the front-door:
CF_DOMAIN=<dist>.cloudfront.net CF_SIGNING_SECRET=pr-preview/cloudfront-signing-key \
  scripts/demo/abca-preview-controller.sh pr <N>
# → deploys onto alb-internal, emits a signed *.cloudfront.net URL, screenshots it.

# sign a URL by hand:
TTL=900 scripts/demo/cf-sign-url.sh "https://<dist>.cloudfront.net/pr-<N>/"
```

Unset `CF_DOMAIN` and the controller falls back to the legacy public-ALB + basic-auth
path — the front-door is strictly additive.

## Operational must-know: keep the internal ALB group warm

The Auto Mode ALB for an Ingress **group is destroyed and recreated when the group
goes empty** (all member Ingresses deleted), which mints a **new ALB ARN**. A VPC
Origin is pinned to one ALB ARN and **cannot be updated while attached to a
distribution** (`CannotUpdateEntityWhileInUse`) — so a churned ALB silently breaks
the front-door (CloudFront still points at the dead ALB; previews go unreachable).

**Fix (required): pin a permanent keepalive Ingress in the internal group** so the
group is never empty and the ALB ARN is stable. Apply the shipped manifest once per
cluster:

```bash
kubectl apply -f charts/preview-env/cloudfront-keepalive.yaml
```

It runs a hardened 2-replica nginx on `alb-internal` with a **PodDisruptionBudget**
(`minAvailable: 1`) so a node drain can't evict the last replica and empty the group.
Never delete it while the front door is in use. Recommended (roadmap): a CloudWatch
alarm on the internal ALB's ARN changing, so a rare recreate is caught immediately.
If the ALB ARN ever does change, you must create a **new** VPC Origin for it and
repoint the distribution's origin (you cannot update the in-use one in place).

## Trade-offs (honest)

- The signed URL carries an `Expires`/`Signature` query string; it appears in the PR
  comment's link href (the label is query-stripped for readability). It is **ephemeral**
  (minutes) — the accepted trade-off for removing the static password.
- CloudFront distribution + VPC Origin changes take ~10-20 min to propagate.
- No per-URL revocation (see above).
