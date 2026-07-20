// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
// Pure decision logic for optional preview Basic Auth — no framework deps, so
// it is trivially unit-testable (mirrors lib/runtime.ts style).

/** Paths that are never gated (health must stay unauthenticated for probes). */
export function isAuthExempt(pathname: string): boolean {
  return pathname.endsWith('/api/health');
}

/**
 * Decide whether a request is allowed.
 * @param expectedB64 configured credential, base64("user:pass"); '' disables auth
 * @param authorizationHeader the request's Authorization header (may be null)
 * @param pathname the request path
 */
export function isAuthorized(
  expectedB64: string,
  authorizationHeader: string | null,
  pathname: string,
): boolean {
  if (!expectedB64) return true; // auth disabled → public-by-default
  if (isAuthExempt(pathname)) return true; // health always open
  const h = authorizationHeader ?? '';
  if (!h.startsWith('Basic ')) return false;
  // Plain `===` (not constant-time). This gate is a low-value convenience wall
  // for preview environments, not a secret-bearing endpoint; the credential is a
  // shared per-preview password, so timing side-channels aren't in the threat
  // model. Use a real IdP (ALB OIDC, `protect.enabled`) for sensitive previews.
  return h.slice('Basic '.length).trim() === expectedB64;
}