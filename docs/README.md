<!-- Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved. -->
<!-- SPDX-License-Identifier: MIT-0 -->
# Documentation

New here? Read in this order:

1. **[ARCHITECTURE.md](ARCHITECTURE.md)** — the *why* and the big picture (how a PR
   becomes a preview URL; the SHA-gated readiness contract; the two diagrams).
2. **[runbook.md](runbook.md)** — the *how*: provision on AWS EKS end to end,
   with the IAM footprint and cost notes.
3. **[onboarding.md](onboarding.md)** — put your own app repo on the platform.

## Reference

- **[CONTEXT.md](../CONTEXT.md)** — domain glossary / ubiquitous language.
- **[agent-loop.md](agent-loop.md)** — the interactive + autonomous (`@claude`) agent loops.
- **[host-mode.md](host-mode.md)** — host routing (`pr-N.<domain>`) vs the default path mode.
- **[verification.md](verification.md)** — what's tested + the live-EKS proof.
- **[SECURITY.md](../SECURITY.md)** — trust boundaries, threat model, and how to report issues.

## Advanced / integrations

- **[abca-integration.md](abca-integration.md)** — pair with Autonomous Background
  Coding Agents (task → PR → preview → screenshot).
- **[design-cloudfront-frontdoor.md](design-cloudfront-frontdoor.md)** — the opt-in
  CloudFront signed-URL front door over a private ALB.
- **[roadmap-production.md](roadmap-production.md)** — what's needed to run this for real.
- **[persona-review-backlog.md](persona-review-backlog.md)** — remaining low-priority polish items from the persona review.
