// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
// preview-status.mjs — pure logic for the Preview Skill's agent loop.
//
// The skill never trusts a reused URL blindly: it gates on BOTH
//   (1) the GitHub Check Run for the *pushed* head SHA == success, and
//   (2) /api/health reporting that same GIT_SHA.
// These functions are pure so they're trivially unit-tested without GitHub or a cluster.

/**
 * Decide what the agent should do next, given the Check Run for the pushed SHA
 * and the latest /api/health probe.
 *
 * @param {object} args
 * @param {string} args.pushedSha        full or short SHA the agent just pushed
 * @param {object|null} args.check       { head_sha, status, conclusion } | null
 * @param {object|null} args.health      { status, ready, sha } | null (null = unreachable)
 * @returns {{ state: string, action: string, reason: string|null }}
 *   state ∈ waiting_check | check_failed | waiting_health | stale | ready
 */
export function decideNextAction({ pushedSha, check, health }) {
  // Match full-vs-short SHAs by prefix, but require a minimum length so a
  // truncated/garbage value (e.g. "dev-local", "ab") can't false-match an
  // unrelated build and weaken the fresh-deploy invariant.
  const MIN_SHA = 7;
  const shaMatches = (a, b) => {
    if (!a || !b) return false;
    if (a === b) return true;
    if (a.length < MIN_SHA || b.length < MIN_SHA) return false;
    return a.startsWith(b) || b.startsWith(a);
  };

  // 1) Gate on the Check Run for OUR sha.
  if (!check || !shaMatches(check.head_sha, pushedSha)) {
    return { state: 'waiting_check', action: 'poll', reason: 'no check yet for pushed sha' };
  }
  if (check.status !== 'completed') {
    return { state: 'waiting_check', action: 'poll', reason: `check ${check.status}` };
  }
  if (check.conclusion !== 'success') {
    return { state: 'check_failed', action: 'read_failure_then_fix', reason: check.conclusion };
  }

  // 2) Check is green — now confirm the live app is serving OUR sha.
  if (!health) {
    return { state: 'waiting_health', action: 'poll', reason: 'health unreachable' };
  }
  if (!health.ready || health.status !== 'ok') {
    return { state: 'waiting_health', action: 'poll', reason: `health ${health.status}` };
  }
  if (!shaMatches(health.sha, pushedSha)) {
    // The URL is up but still serving the previous build — do NOT test it.
    return { state: 'stale', action: 'poll', reason: `serving ${health.sha}, want ${pushedSha}` };
  }

  return { state: 'ready', action: 'run_checks', reason: null };
}

/**
 * Extract the structured failure reason from a Check Run's output summary.
 * The workflow writes lines like "reason: ImagePullBackOff".
 * @param {string} summary
 * @returns {string}
 */
export function parseFailureReason(summary) {
  if (!summary) return 'Unknown';
  const m = /reason:\s*([A-Za-z][A-Za-z0-9_]*)/.exec(summary);
  return m ? m[1] : 'Unknown';
}

/**
 * Map a structured failure reason to a concrete suggested next step for the agent.
 * @param {string} reason
 */
export function suggestRemediation(reason) {
  const table = {
    MissingEnvVar: 'Add the missing env var to the Helm values / Preview Scope and push.',
    ImagePullBackOff: 'Check the image build/push step and the ECR tag; rebuild.',
    HealthCheckFailed: 'App started but /api/health is failing — inspect app logs for a runtime error.',
    RoutingNotReady: 'Ingress/ALB not routing yet — verify the Ingress host/path and ALB registration.',
    ReadinessTimeout: 'Pod never became ready within the timeout — check resource limits / boot time.',
    CrashLoopBackOff: 'Container is crashing on boot — read the crash logs and fix the entrypoint error.',
  };
  return table[reason] ?? 'Inspect the Check Run output and pod logs, then fix and re-push.';
}