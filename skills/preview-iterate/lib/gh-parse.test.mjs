// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import { describe, it, expect } from 'vitest';
import { parseCheck, parseDeploymentId, parseEnvUrl, parseHealth } from './gh-parse.mjs';

describe('parseCheck', () => {
  it('parses a full check run', () => {
    const out = JSON.stringify({
      head_sha: 'abcdef1234567890',
      status: 'completed',
      conclusion: 'success',
      output: { summary: 'Preview ready\n\nURL: http://x/pr-1' },
    });
    expect(parseCheck(out)).toEqual({
      head_sha: 'abcdef1234567890',
      status: 'completed',
      conclusion: 'success',
      summary: 'Preview ready\n\nURL: http://x/pr-1',
    });
  });
  it('returns null for the literal "null" (no preview check yet)', () => {
    expect(parseCheck('null')).toBeNull();
    expect(parseCheck('')).toBeNull();
    expect(parseCheck('   ')).toBeNull();
  });
  it('returns null on malformed JSON instead of throwing', () => {
    expect(parseCheck('<html>500</html>')).toBeNull();
  });
  it('defaults a missing output.summary to empty string', () => {
    const out = JSON.stringify({ head_sha: 's', status: 'completed', conclusion: 'failure' });
    expect(parseCheck(out).summary).toBe('');
  });
});

describe('parseDeploymentId', () => {
  it('returns the trimmed id', () => {
    expect(parseDeploymentId('123456\n')).toBe('123456');
  });
  it('returns null when empty or "null"', () => {
    expect(parseDeploymentId('')).toBeNull();
    expect(parseDeploymentId('null')).toBeNull();
    expect(parseDeploymentId('  \n')).toBeNull();
  });
});

describe('parseEnvUrl', () => {
  it('returns the trimmed url', () => {
    expect(parseEnvUrl('http://alb/pr-1\n')).toBe('http://alb/pr-1');
  });
  it('returns null when empty or "null" (status with no environment_url)', () => {
    expect(parseEnvUrl('')).toBeNull();
    expect(parseEnvUrl('null')).toBeNull();
  });
});

describe('parseHealth', () => {
  it('parses a health JSON body', () => {
    expect(parseHealth('{"status":"ok","ready":true,"sha":"abc1234"}')).toEqual({
      status: 'ok', ready: true, sha: 'abc1234',
    });
  });
  it('returns null for non-JSON (curl got HTML/empty on an HTTP error)', () => {
    expect(parseHealth('<html>404</html>')).toBeNull();
    expect(parseHealth('')).toBeNull();
  });
  it('returns null for a JSON scalar (not an object)', () => {
    expect(parseHealth('42')).toBeNull();
    expect(parseHealth('"ok"')).toBeNull();
  });
});