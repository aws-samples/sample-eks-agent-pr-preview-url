# Production-hardening roadmap

The core platform ships hardened for real use: CI-gated test suite, cdk-nag
security gate, namespace guardrails, reliable teardown, and the SHA-gated agent
loop. This document lists the **next track** — operational weight deliberately
**not built yet**, to adopt as concrete needs appear rather than speculatively.

Each item below is a self-contained follow-up; pick it up when it earns its keep.

## Observability (full stack)

- **Prometheus + Grafana**: scrape pod + app metrics; dashboards for
 time-to-ready, build-cache hit ratio, ALB registration latency, per-preview
 CPU/mem. (Phase 3 shipped only metrics-server + structured logs + a
 per-deploy timing metric.)
- **OpenTelemetry tracing**: spans across webhook → build → deploy → health →
 status, to find slow legs.
- **Centralized logs**: ship app + control-plane logs to CloudWatch Logs
 Insights (or Loki) with correlation by pr/sha (the JSON logger already emits
 those fields).
- **Alerting + SLOs**: error budgets and alerts on time-to-ready regressions,
 teardown failures, orphan accumulation.

## Stability / scale

- **HPA + multi-replica** previews (today: 1 replica) with cross-AZ spread for
 previews that need availability under load.
- **PodDisruptionBudget tuning** beyond the single-replica `minAvailable: 0`.
- **Blue/green or canary for the platform itself** (the reusable workflow +
 chart), not just the previewed app.
- **Build acceleration**: registry layer cache hit-ratio tracking, pre-warmed
 base images, monorepo path-filtering to skip unaffected apps.

## URLs & access

- **Host-mode HTTPS by default:** Route53 + ACM wildcard so
 previews are `https://pr-N.preview.<domain>` with image reuse — the clean
 per-PR subdomain URL. (the default ships path-mode HTTP).
- **Comment-on-preview** (the remaining preview-comment parity gap): a review-toolbar-style review widget injected into the preview, synced to the PR. Notable build
 (inject + sync path) — left for this track.

## Data

- **Per-PR database** option (beyond schema isolation) for workloads
 that need engine-level isolation or destructive migration testing — with
 seeding + branched data.

## Multi-tenancy (the biggest leap)

- Durable control-plane state, multiple repos/teams, per-team quotas + chargeback,
 an MCP server for agents — the "platform product" the original research
 described. Only if this becomes an internal product.

## Promotion criteria

Pick an item up when: (a) the platform has run reliably through real multi-PR /
multi-commit use, (b) there's a concrete need the item addresses (not
speculative), and (c) its added operational weight is justified. Add tests +
observability + guardrails with the feature, and keep the CI gate green.
