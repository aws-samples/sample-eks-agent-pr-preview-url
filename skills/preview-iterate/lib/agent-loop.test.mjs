// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import { describe, it, expect } from 'vitest';
import { loopControl, actorAllowed } from './agent-loop.mjs';

describe('loopControl — stop conditions', () => {
  const base = { iteration: 0, maxIterations: 3, spentUsd: 0, budgetUsd: 5, state: 'check_failed' };

  it('stops immediately on ready (terminal success)', () => {
    expect(loopControl({ ...base, state: 'ready' })).toMatchObject({ stop: true, reason: 'ready' });
  });
  it('attempts a fix on check_failed within caps', () => {
    expect(loopControl(base)).toMatchObject({ continue: true, reason: 'attempt_fix' });
  });
  it('stops at the iteration cap', () => {
    expect(loopControl({ ...base, iteration: 3 })).toMatchObject({ stop: true, reason: 'max_iterations' });
  });
  it('stops when the budget is exceeded', () => {
    expect(loopControl({ ...base, spentUsd: 5, budgetUsd: 5 })).toMatchObject({ stop: true, reason: 'budget_exceeded' });
  });
  it('iteration cap takes precedence over a fixable failure', () => {
    expect(loopControl({ ...base, iteration: 99, state: 'check_failed' }).stop).toBe(true);
  });
  it('polls (no fix iteration consumed) on transient states', () => {
    for (const state of ['waiting_check', 'waiting_health', 'stale']) {
      expect(loopControl({ ...base, state })).toMatchObject({ continue: true, reason: 'poll' });
    }
  });
  it('budgetUsd<=0 means unlimited cost', () => {
    expect(loopControl({ ...base, spentUsd: 1000, budgetUsd: 0 }).reason).toBe('attempt_fix');
  });
});

describe('actorAllowed — same-repo only', () => {
  const allowedRepo = 'your-org/pr-preview';
  it('allows same-repo non-fork', () => {
    expect(actorAllowed({ eventRepo: allowedRepo, allowedRepo, isFork: false })).toBe(true);
  });
  it('refuses forks', () => {
    expect(actorAllowed({ eventRepo: allowedRepo, allowedRepo, isFork: true })).toBe(false);
  });
  it('refuses other repos', () => {
    expect(actorAllowed({ eventRepo: 'someone/else', allowedRepo, isFork: false })).toBe(false);
  });
});