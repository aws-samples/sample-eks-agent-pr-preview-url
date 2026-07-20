// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import { describe, it, expect } from 'vitest';
import { isAuthExempt, isAuthorized } from './basic-auth';

const CRED = Buffer.from('demo:secret').toString('base64'); // "ZGVtbzpzZWNyZXQ="

describe('isAuthExempt', () => {
  it('exempts /api/health (root and basePath forms)', () => {
    expect(isAuthExempt('/api/health')).toBe(true);
    expect(isAuthExempt('/pr-42/api/health')).toBe(true);
  });
  it('does not exempt app pages', () => {
    expect(isAuthExempt('/')).toBe(false);
    expect(isAuthExempt('/pr-42/diagnostics')).toBe(false);
  });
});

describe('isAuthorized', () => {
  it('is public when no credential is configured', () => {
    expect(isAuthorized('', null, '/')).toBe(true);
    expect(isAuthorized('', null, '/diagnostics')).toBe(true);
  });
  it('always allows health, even when auth is on and no header sent', () => {
    expect(isAuthorized(CRED, null, '/api/health')).toBe(true);
    expect(isAuthorized(CRED, null, '/pr-1/api/health')).toBe(true);
  });
  it('rejects a gated page with no/!Basic header', () => {
    expect(isAuthorized(CRED, null, '/')).toBe(false);
    expect(isAuthorized(CRED, 'Bearer xyz', '/')).toBe(false);
  });
  it('rejects wrong credentials', () => {
    const wrong = Buffer.from('demo:nope').toString('base64');
    expect(isAuthorized(CRED, `Basic ${wrong}`, '/')).toBe(false);
  });
  it('accepts the exact configured credential', () => {
    expect(isAuthorized(CRED, `Basic ${CRED}`, '/')).toBe(true);
    expect(isAuthorized(CRED, `Basic ${CRED}`, '/diagnostics')).toBe(true);
  });
  it('tolerates whitespace after the Basic scheme', () => {
    expect(isAuthorized(CRED, `Basic  ${CRED}`, '/')).toBe(true);
  });
});