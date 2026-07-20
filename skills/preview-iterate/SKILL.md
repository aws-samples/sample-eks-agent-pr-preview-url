---
name: preview-iterate
description: Drive the pr-preview agent loop — open/update a PR, wait for its Preview Environment to be ready (SHA-gated), run checks against the live URL, and iterate on failures. Use when iterating on a PR that has a preview deployment on the EKS PR-preview platform.
---

# preview-iterate

Interactive loop (v1) for iterating on a PR against its Preview
Environment. The status source of truth is **GitHub Deployments + Check Runs +
the live `/api/health`** — there is no control-plane API.

## The one rule: never test a stale deployment

The preview URL is reused across pushes. After you push a fix, the old pod may
still be serving the old code at the same URL. So **before running any check**,
gate on BOTH:

1. the Check Run named `preview` for **your pushed SHA** has `conclusion: success`, and
2. `GET <url>/api/health` returns `{ ready: true, sha: <your pushed SHA> }`.

`lib/preview-status.mjs::decideNextAction` (in this skill) encodes this. Only
`state: ready` (`action: run_checks`) means it's safe to test.

## Loop

1. Make the code change; commit and push to the PR branch. Record the pushed SHA.
2. `node skills/preview-iterate/preview-skill.mjs watch --repo <owner/repo> --pr <n> --sha <pushed-sha>`
   - It polls until `ready` (prints the snapshot JSON and exits 0), or
   - exits 1 with `terminal: failed` and a structured `failure.reason` +
     `failure.remediation`, or `terminal: timeout`.
3. On `ready`: run your checks against `url` (curl endpoints, hit `/diagnostics`,
   run e2e). The snapshot's `url` already includes the basePath in path mode.
4. On `failed`: read `failure.reason` (e.g. `ImagePullBackOff`, `MissingEnvVar`,
   `HealthCheckFailed`) and `failure.remediation`, fix the code, and go to step 1.

## One-shot status

`node skills/preview-iterate/preview-skill.mjs status --repo <owner/repo> --pr <n> --sha <sha>`
prints a single JSON snapshot — useful for scripting or a quick check.

## Requirements

- `gh` authenticated (`gh auth status`)
- `curl`, Node ≥ 18

## Notes

- Short and full SHAs both match (the workflow tags images with the short SHA).
- This is the **interactive** skill; the autonomous CI agent (`@claude` on a PR,
  see [`docs/agent-loop.md`](../../docs/agent-loop.md)) is the unattended counterpart.
