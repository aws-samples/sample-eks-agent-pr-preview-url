// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { getRuntimeInfo, checkDatabase, bootDelayMs, dbSchemaName } from './runtime';

describe('getRuntimeInfo', () => {
  const saved = { ...process.env };
  afterEach(() => {
    process.env = { ...saved };
  });

  it('reports the baked build SHA', () => {
    process.env.BUILD_GIT_SHA = 'abc123';
    expect(getRuntimeInfo().buildSha).toBe('abc123');
  });

  it('defaults routing mode to host', () => {
    delete process.env.PREVIEW_ROUTING_MODE;
    expect(getRuntimeInfo().routingMode).toBe('host');
  });

  it('derives the PR number from a /pr-N basePath', () => {
    process.env.PREVIEW_BASE_PATH = '/pr-42';
    delete process.env.PREVIEW_PR_NUMBER;
    expect(getRuntimeInfo().prNumber).toBe('42');
  });

  it('prefers an explicit PREVIEW_PR_NUMBER over the basePath', () => {
    process.env.PREVIEW_BASE_PATH = '/pr-42';
    process.env.PREVIEW_PR_NUMBER = '99';
    expect(getRuntimeInfo().prNumber).toBe('99');
  });

  it('returns null PR number when nothing identifies it', () => {
    delete process.env.PREVIEW_BASE_PATH;
    delete process.env.PREVIEW_PR_NUMBER;
    expect(getRuntimeInfo().prNumber).toBeNull();
  });
});

describe('checkDatabase', () => {
  const saved = { ...process.env };
  afterEach(() => {
    process.env = { ...saved };
  });

  it('reports unconfigured when DATABASE_URL is absent', async () => {
    delete process.env.DATABASE_URL;
    const r = await checkDatabase();
    expect(r.configured).toBe(false);
    expect(r.ok).toBe(false);
    expect(r.detail).toBe('DATABASE_URL not set');
    expect(r.visits).toEqual([]);
    expect(r.totalVisits).toBeNull();
  });

  it('never throws and reports an error for an unreachable DB', async () => {
    // Reserved TEST-NET-1 address → connection will fail fast within the timeout.
    process.env.DATABASE_URL = 'postgresql://u:p@192.0.2.1:5432/db';
    const r = await checkDatabase(400);
    expect(r.configured).toBe(true);
    expect(r.ok).toBe(false);
    expect(typeof r.detail).toBe('string');
    // On failure it still returns the structured shape, no rows.
    expect(r.visits).toEqual([]);
    expect(r.serverVersion).toBeNull();
  });
});

describe('dbSchemaName — per-PR schema isolation', () => {
  const saved = { ...process.env };
  afterEach(() => {
    process.env = { ...saved };
  });

  it('derives pr_<n> from the PR number', () => {
    delete process.env.PREVIEW_DB_SCHEMA;
    process.env.PREVIEW_PR_NUMBER = '42';
    expect(dbSchemaName()).toBe('pr_42');
  });

  it('gives different PRs different schemas (isolation)', () => {
    delete process.env.PREVIEW_DB_SCHEMA;
    process.env.PREVIEW_PR_NUMBER = '42';
    const a = dbSchemaName();
    process.env.PREVIEW_PR_NUMBER = '51';
    const b = dbSchemaName();
    expect(a).not.toBe(b);
    expect([a, b]).toEqual(['pr_42', 'pr_51']);
  });

  it('prefers an explicit PREVIEW_DB_SCHEMA', () => {
    process.env.PREVIEW_DB_SCHEMA = 'pr_99';
    process.env.PREVIEW_PR_NUMBER = '42';
    expect(dbSchemaName()).toBe('pr_99');
  });

  it('sanitizes injection attempts to a safe identifier', () => {
    process.env.PREVIEW_DB_SCHEMA = 'pr_1"; DROP TABLE users;--';
    const s = dbSchemaName();
    expect(s).toMatch(/^[a-z_][a-z0-9_]*$/);
    expect(s).not.toContain('"');
    expect(s).not.toContain(' ');
    expect(s).not.toContain(';');
  });

  it('prefixes a leading digit so the identifier is valid', () => {
    process.env.PREVIEW_DB_SCHEMA = '9bad';
    expect(dbSchemaName()).toMatch(/^_9bad$/);
  });

  it('falls back to "preview" when nothing identifies the PR', () => {
    delete process.env.PREVIEW_DB_SCHEMA;
    delete process.env.PREVIEW_PR_NUMBER;
    expect(dbSchemaName()).toBe('preview');
  });
});

describe('bootDelayMs', () => {
  const saved = { ...process.env };
  afterEach(() => {
    process.env = { ...saved };
  });

  it('returns 0 by default', () => {
    delete process.env.PREVIEW_BOOT_DELAY_MS;
    expect(bootDelayMs()).toBe(0);
  });

  it('parses a positive delay', () => {
    process.env.PREVIEW_BOOT_DELAY_MS = '2500';
    expect(bootDelayMs()).toBe(2500);
  });

  it('ignores nonsense values', () => {
    process.env.PREVIEW_BOOT_DELAY_MS = 'not-a-number';
    expect(bootDelayMs()).toBe(0);
  });
});