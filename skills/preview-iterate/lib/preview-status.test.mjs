// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import { describe, it, expect } from 'vitest';
import { decideNextAction, parseFailureReason, suggestRemediation } from './preview-status.mjs';

const SHA = 'abcdef1234567890';
const SHORT = 'abcdef123456';

describe('decideNextAction — the SHA-gated fresh-deploy invariant', () => {
  it('waits when no check exists for the pushed sha', () => {
    const r = decideNextAction({ pushedSha: SHA, check: null, health: null });
    expect(r.state).toBe('waiting_check');
    expect(r.action).toBe('poll');
  });

  it('waits when the only check is for a different sha', () => {
    const r = decideNextAction({
      pushedSha: SHA,
      check: { head_sha: 'deadbeefdeadbeef', status: 'completed', conclusion: 'success' },
      health: { status: 'ok', ready: true, sha: 'deadbeef' },
    });
    expect(r.state).toBe('waiting_check');
  });

  it('waits while the check is still in_progress', () => {
    const r = decideNextAction({ pushedSha: SHA, check: { head_sha: SHA, status: 'in_progress' }, health: null });
    expect(r.state).toBe('waiting_check');
  });

  it('reports check_failed and routes to remediation', () => {
    const r = decideNextAction({
      pushedSha: SHA,
      check: { head_sha: SHA, status: 'completed', conclusion: 'failure' },
      health: null,
    });
    expect(r.state).toBe('check_failed');
    expect(r.action).toBe('read_failure_then_fix');
  });

  it('does NOT run checks while health still serves the OLD sha (stale guard)', () => {
    const r = decideNextAction({
      pushedSha: SHA,
      check: { head_sha: SHA, status: 'completed', conclusion: 'success' },
      health: { status: 'ok', ready: true, sha: 'oldsha000000' },
    });
    expect(r.state).toBe('stale');
    expect(r.action).toBe('poll'); // critically: not run_checks
  });

  it('waits when health is unreachable even after a green check', () => {
    const r = decideNextAction({
      pushedSha: SHA,
      check: { head_sha: SHA, status: 'completed', conclusion: 'success' },
      health: null,
    });
    expect(r.state).toBe('waiting_health');
  });

  it('is ready only when check is green AND health serves our sha', () => {
    const r = decideNextAction({
      pushedSha: SHA,
      check: { head_sha: SHA, status: 'completed', conclusion: 'success' },
      health: { status: 'ok', ready: true, sha: SHA },
    });
    expect(r.state).toBe('ready');
    expect(r.action).toBe('run_checks');
  });

  it('tolerates short-vs-full sha matching in both directions', () => {
    const r = decideNextAction({
      pushedSha: SHORT,
      check: { head_sha: SHA, status: 'completed', conclusion: 'success' },
      health: { status: 'ok', ready: true, sha: SHORT },
    });
    expect(r.state).toBe('ready');
  });
});

describe('parseFailureReason', () => {
  it('extracts a structured reason token', () => {
    expect(parseFailureReason('reason: ImagePullBackOff\n\nmore text')).toBe('ImagePullBackOff');
  });
  it('falls back to Unknown', () => {
    expect(parseFailureReason('no structured reason here')).toBe('Unknown');
    expect(parseFailureReason('')).toBe('Unknown');
  });
});

describe('suggestRemediation', () => {
  it('maps known reasons to concrete advice', () => {
    expect(suggestRemediation('MissingEnvVar')).toMatch(/env var/i);
    expect(suggestRemediation('ImagePullBackOff')).toMatch(/image|ECR/i);
  });
  it('has a sane default', () => {
    expect(suggestRemediation('SomethingNew')).toMatch(/inspect/i);
  });
});