#!/usr/bin/env node
// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
// preview-skill.mjs — the interactive Preview Skill CLI.
//
// Reads Preview Status from GitHub (Deployments + Check Runs) and the live
// /api/health endpoint, applies the SHA-gated fresh-deploy invariant, and tells
// the agent what to do next. Status source is GitHub + the URL — there is no
// control-plane API.
//
// Usage:
//   preview-skill.mjs watch  --repo o/r --pr 42 --sha <pushed-sha> [--timeout 600]
//   preview-skill.mjs status --repo o/r --pr 42 --sha <pushed-sha>   # one-shot JSON
//
// Requires: `gh` (authenticated) and `curl`. Pure decision logic lives in
// lib/preview-status.mjs and is unit-tested separately.
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { decideNextAction, parseFailureReason, suggestRemediation } from './lib/preview-status.mjs';
import { parseCheck, parseDeploymentId, parseEnvUrl, parseHealth } from './lib/gh-parse.mjs';

const pexec = promisify(execFile);

function parseArgs(argv) {
  const a = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const t = argv[i];
    if (t.startsWith('--')) a[t.slice(2)] = argv[++i];
    else a._.push(t);
  }
  return a;
}

async function gh(args) {
  const { stdout } = await pexec('gh', args, { maxBuffer: 8 * 1024 * 1024 });
  return stdout;
}

// Latest Check Run named "preview" for a given commit SHA.
async function getCheck(repo, sha) {
  try {
    const out = await gh([
      'api',
      `repos/${repo}/commits/${sha}/check-runs`,
      '--jq',
      '[.check_runs[] | select(.name=="preview")] | sort_by(.started_at) | last',
    ]);
    return parseCheck(out);
  } catch {
    return null;
  }
}

// environment_url from the most recent deployment for this PR.
async function getDeploymentUrl(repo, pr) {
  try {
    const out = await gh([
      'api',
      `repos/${repo}/deployments?environment=preview/pr-${pr}`,
      '--jq',
      '.[0].id',
    ]);
    const id = parseDeploymentId(out);
    if (!id) return null;
    const st = await gh([
      'api',
      `repos/${repo}/deployments/${id}/statuses`,
      '--jq',
      '.[0].environment_url',
    ]);
    return parseEnvUrl(st);
  } catch {
    return null;
  }
}

async function getHealth(url) {
  if (!url) return null;
  try {
    const { stdout } = await pexec('curl', ['-s', '-m', '5', `${url}/api/health`]);
    return parseHealth(stdout);
  } catch {
    return null;
  }
}

async function snapshot(repo, pr, sha) {
  const [check, url] = await Promise.all([getCheck(repo, sha), getDeploymentUrl(repo, pr)]);
  const health = await getHealth(url);
  const decision = decideNextAction({ pushedSha: sha, check, health });
  const result = { repo, pr, sha, url, decision };
  if (decision.state === 'check_failed' && check?.summary) {
    const reason = parseFailureReason(check.summary);
    result.failure = { reason, remediation: suggestRemediation(reason) };
  }
  return result;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const cmd = args._[0];
  const { repo, pr, sha } = args;
  if (!repo || !pr || !sha) {
    console.error('required: --repo <owner/repo> --pr <n> --sha <pushed-sha>');
    process.exit(2);
  }

  if (cmd === 'status') {
    console.log(JSON.stringify(await snapshot(repo, pr, sha), null, 2));
    return;
  }

  if (cmd === 'watch') {
    const timeout = Number.parseInt(args.timeout ?? '600', 10) * 1000;
    const interval = Number.parseInt(args.interval ?? '6', 10) * 1000;
    const deadline = Date.now() + timeout;
    for (;;) {
      const snap = await snapshot(repo, pr, sha);
      const { state, reason } = snap.decision;
      process.stderr.write(`[${new Date().toISOString()}] ${state}${reason ? ` (${reason})` : ''}\n`);
      if (state === 'ready') {
        console.log(JSON.stringify({ ...snap, terminal: 'ready' }, null, 2));
        return;
      }
      if (state === 'check_failed') {
        console.log(JSON.stringify({ ...snap, terminal: 'failed' }, null, 2));
        process.exit(1);
      }
      if (Date.now() > deadline) {
        console.log(JSON.stringify({ ...snap, terminal: 'timeout' }, null, 2));
        process.exit(1);
      }
      await new Promise((r) => setTimeout(r, interval));
    }
  }

  console.error(`unknown command: ${cmd}`);
  process.exit(2);
}

main().catch((e) => {
  console.error(e?.message ?? e);
  process.exit(1);
});
