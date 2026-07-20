# Agent loop

Two ways to iterate on a PR against its Preview Environment: a **local
interactive loop** (the hero) and an **autonomous CI loop**. Both are built on
one rule — never test a stale deployment — and both read status from the same
place: GitHub Deployments + Check Runs + the live `/api/health`. There is no
control-plane API. For the invariant's rationale, see
[`ARCHITECTURE.md`](./ARCHITECTURE.md).

## The one rule: never test stale code

The preview URL is reused across pushes, so after a fix the old pod may still be
serving old code at the same URL. Before running any check, gate on **both** for
the SHA you pushed:

1. the `preview` Check Run for that SHA has `conclusion: success`, and
2. `GET <url>/api/health` returns `{ ready: true, sha: <pushed SHA> }`.

Only then is it safe to test.

## Local interactive loop (the hero)

The `skills/preview-iterate` skill drives the loop locally and interactively:

```bash
# after committing + pushing a fix, record the pushed SHA, then:
node skills/preview-iterate/preview-skill.mjs watch \
  --repo <owner/repo> --pr <n> --sha <pushed-sha>
```

- `watch` polls until the preview is **ready** for your SHA (prints the snapshot
  JSON, exits 0), or exits non-zero with a terminal `failed` (carrying a
  structured `failure.reason` + `failure.remediation`) or `timeout`.
- `status` prints a single snapshot — handy for scripting or a quick check.

On `ready`, run your checks against `url` (the snapshot's `url` already includes
the basePath in path mode). On `failed`, read the reason (e.g.
`ImagePullBackOff`, `HealthCheckFailed`), fix, push, and loop. Requires `gh`
authenticated, `curl`, and Node ≥ 18.

## Autonomous CI loop

`.github/workflows/preview-agent.yml` is the autonomous variant: it reacts to an
`@claude` mention on a PR and drives the same SHA-gated loop, iterating on
confirmed failures within hard caps. It's reusable — called from the app repo on
`issue_comment`.

**Auth.** Defaults to **Amazon Bedrock** via GitHub OIDC (set the
`AWS_ROLE_TO_ASSUME` secret). An **API-key variant** uses the direct Anthropic
API — set `ANTHROPIC_API_KEY` and pass `auth: api-key`. The default model is
`us.anthropic.claude-sonnet-5`.

**Guard + caps.** A guard job proceeds only when the commenter has **write access**
(`author_association` is `OWNER`, `MEMBER`, or `COLLABORATOR` — so drive-by
comments from non-collaborators are refused) *and* the comment actually mentions
`@claude`; the untrusted comment body is only ever read as data, never
interpolated into the prompt. Runs are bounded by `max_iterations` and
`budget_usd` inputs, and by `claude-code-action`'s `--max-turns` hard per-run
cap. `concurrency` cancels an in-flight loop when a newer trigger arrives.

**Honest scope.** The v1 workflow is a **bounded single invocation** of
`anthropics/claude-code-action@v1` with `--max-turns`. Hard,
harness-enforced multi-invocation looping via `claude-code-base-action` is a
**labeled next phase**, not what ships today. The pure continue/stop decision
the loop should follow — terminal success, iteration cap, budget ceiling, and
"only a confirmed failure warrants a fix attempt" — is unit-tested in
`skills/preview-iterate/lib/agent-loop.mjs` (`loopControl` / `actorAllowed`), so
the contract is verified independently of the agent and of GitHub.
