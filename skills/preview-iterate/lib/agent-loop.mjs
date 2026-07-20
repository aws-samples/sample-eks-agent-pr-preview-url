// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
// agent-loop.mjs — pure loop-control for the autonomous CI agent (Phase 5).
//
// The autonomous @claude agent reuses the SHA-gated decideNextAction logic, but
// must STOP — never run unbounded. This module is the pure stop/continue
// decision so the guardrails (iteration cap, cost ceiling, success/terminal
// states) are unit-tested without invoking the agent or GitHub.

/**
 * Decide whether the autonomous agent should continue iterating or stop.
 *
 * @param {object} s
 * @param {number} s.iteration     iterations already completed (0-based count of attempts)
 * @param {number} s.maxIterations hard cap on fix attempts
 * @param {number} s.spentUsd      cost spent so far (USD)
 * @param {number} s.budgetUsd     cost ceiling (USD); <=0 means unlimited
 * @param {string} s.state         latest decideNextAction state
 *                                 (ready | check_failed | stale | waiting_check | waiting_health)
 * @returns {{continue:boolean, stop:boolean, reason:string}}
 */
export function loopControl(s) {
  const { iteration, maxIterations, spentUsd = 0, budgetUsd = 0, state } = s;

  // Terminal success: the preview is ready for the pushed SHA — hand back to human/tests.
  if (state === 'ready') return { continue: false, stop: true, reason: 'ready' };

  // Hard caps take precedence over any further work.
  if (iteration >= maxIterations) {
    return { continue: false, stop: true, reason: 'max_iterations' };
  }
  if (budgetUsd > 0 && spentUsd >= budgetUsd) {
    return { continue: false, stop: true, reason: 'budget_exceeded' };
  }

  // Only a confirmed failure warrants an agent fix attempt. Transient states
  // (waiting_*, stale) are polled by the skill, not "fixed" by the agent.
  if (state === 'check_failed') {
    return { continue: true, stop: false, reason: 'attempt_fix' };
  }

  // Anything else: keep waiting (poll), do not consume a fix iteration.
  return { continue: true, stop: false, reason: 'poll' };
}

/**
 * Whether an actor is allowed to drive the agent. Same-repo only — fork PRs and
 * other repos are refused (reuses the OIDC same-repo posture).
 * @param {object} ctx
 * @param {string} ctx.eventRepo   owner/repo the event came from
 * @param {string} ctx.allowedRepo the platform's repo (owner/repo)
 * @param {boolean} ctx.isFork     whether the PR head is a fork
 * @returns {boolean}
 */
export function actorAllowed(ctx) {
  if (ctx.isFork) return false;
  return ctx.eventRepo === ctx.allowedRepo;
}