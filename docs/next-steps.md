<!-- Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved. -->
<!-- SPDX-License-Identifier: MIT-0 -->
# What's here now, and what's next

A public-facing snapshot of recently-landed capabilities and the highest-value
follow-ups. For the full production-hardening plan see
[roadmap-production.md](roadmap-production.md); for security trust boundaries see
[SECURITY.md](../SECURITY.md).

## Recently landed

- **Optional CloudFront front door** — signed-URL access over a **private** ALB
  (CloudFront VPC Origin), stronger than the default basic-auth wall, with trusted
  TLS on `*.cloudfront.net` and no public domain required. See
  [design-cloudfront-frontdoor.md](design-cloudfront-frontdoor.md).
- **ABCA integration** — a fully autonomous task → PR → preview → verified-screenshot
  loop. See [abca-integration.md](abca-integration.md).
- **Verifiable teardown + fail-closed reaper** — previews are torn down and confirmed
  reaped; the scheduled sweep refuses to run on an empty/failed open-set and caps how
  many it will delete at once.

## Recommended follow-ups (highest value first)

1. **Tighten multi-tenant isolation** before running untrusted PRs from many teams:
   per-PR database roles (not a shared user), NetworkPolicy that isolates previews
   from each other, and destination-scoped egress. See
   [SECURITY.md](../SECURITY.md) → *Trust boundaries*.
2. **Scope the CI trust** — default the GitHub OIDC deploy role to an explicit repo
   allowlist rather than org-wide, and narrow its Kubernetes RBAC below cluster-admin.
3. **Enforce agent budgets in the harness** — today `max_iterations` / `budget_usd`
   bound the loop that a driver runs; wire them into an unattended multi-invocation
   harness so they're enforced, not advisory (see [agent-loop.md](agent-loop.md)).
4. **Observability + alerting** — Prometheus/OTel, centralized logs, and alarms on the
   CloudFront front-door's keepalive and on orphan accumulation.

## Measured deploy timing

On EKS Auto Mode, path mode: **~44 s** from "start deploying this PR" to an
agent-testable URL on a warm image build; **~2.5–3 min** worst case on a cold
dependency change (the container build dominates, not Kubernetes). See
[verification.md](verification.md).
