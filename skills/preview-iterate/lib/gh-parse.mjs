// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
// gh-parse.mjs — pure parsers for the GitHub/curl I/O layer of the Preview Skill.
//
// The I/O functions in preview-skill.mjs are thin: they exec `gh`/`curl` and
// hand the raw stdout to these pure functions. Keeping the parsing here makes
// the failure-prone bits (null handling, trimming, optional chaining) unit
// testable without stubbing child processes.

/**
 * Parse the result of `gh api .../check-runs --jq '... | last'` for the
 * "preview" check. The jq already selected the latest preview check (or null).
 * @param {string} stdout raw gh stdout (JSON of one check run, or "null"/"")
 * @returns {{head_sha:string,status:string,conclusion:string,summary:string}|null}
 */
export function parseCheck(stdout) {
  let c;
  try {
    c = JSON.parse((stdout || '').trim() || 'null');
  } catch {
    return null;
  }
  if (!c || typeof c !== 'object') return null;
  return {
    head_sha: c.head_sha ?? '',
    status: c.status ?? '',
    conclusion: c.conclusion ?? '',
    summary: c.output?.summary ?? '',
  };
}

/**
 * Parse a deployment id from `gh api .../deployments?... --jq '.[0].id'`.
 * gh prints the bare value (a number) or empty when there are no deployments.
 * @param {string} stdout
 * @returns {string|null} the id as a string, or null if absent
 */
export function parseDeploymentId(stdout) {
  const id = (stdout || '').trim();
  if (!id || id === 'null') return null;
  return id;
}

/**
 * Parse the environment_url from `gh api .../statuses --jq '.[0].environment_url'`.
 * @param {string} stdout
 * @returns {string|null}
 */
export function parseEnvUrl(stdout) {
  const u = (stdout || '').trim();
  if (!u || u === 'null') return null;
  return u;
}

/**
 * Parse the /api/health JSON body from curl. Returns null on any non-JSON
 * (curl exits 0 on HTTP errors and emits HTML/empty), so the caller treats a
 * broken endpoint as "not ready / unreachable" rather than crashing.
 * @param {string} stdout
 * @returns {object|null}
 */
export function parseHealth(stdout) {
  try {
    const v = JSON.parse((stdout || '').trim());
    return v && typeof v === 'object' ? v : null;
  } catch {
    return null;
  }
}