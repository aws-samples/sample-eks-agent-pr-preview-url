// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import { describe, it, expect, afterEach } from 'vitest';
import { format } from './logger';

describe('structured logger format', () => {
  const saved = { ...process.env };
  afterEach(() => { process.env = { ...saved }; });

  it('emits a single valid JSON line with level + msg', () => {
    const line = format('info', 'health.ok');
    expect(line).not.toContain('\n');
    const o = JSON.parse(line);
    expect(o.level).toBe('info');
    expect(o.msg).toBe('health.ok');
  });

  it('enriches with the preview identity from runtime', () => {
    process.env.BUILD_GIT_SHA = 'abc1234';
    process.env.PREVIEW_PR_NUMBER = '42';
    process.env.PREVIEW_ROUTING_MODE = 'path';
    const o = JSON.parse(format('info', 'x'));
    expect(o.pr).toBe('42');
    expect(o.sha).toBe('abc1234');
    expect(o.schema).toBe('pr_42');
    expect(o.routingMode).toBe('path');
    expect(o.service).toContain('reference-workload');
  });

  it('merges caller fields', () => {
    const o = JSON.parse(format('warn', 'slow', { route: '/api/health', latencyMs: 1200 }));
    expect(o.route).toBe('/api/health');
    expect(o.latencyMs).toBe(1200);
    expect(o.level).toBe('warn');
  });

  it('includes time only when provided (deterministic by default)', () => {
    expect(JSON.parse(format('info', 'x')).time).toBeUndefined();
    expect(JSON.parse(format('info', 'x', {}, '2026-01-01T00:00:00Z')).time).toBe('2026-01-01T00:00:00Z');
  });
});