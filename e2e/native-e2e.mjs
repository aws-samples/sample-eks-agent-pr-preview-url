#!/usr/bin/env node
// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
// native-e2e.mjs — process-level end-to-end for the preview golden path.
//
// WHY native (not in-cluster): on this host the Docker daemon is wedged by a
// 100%-full data volume, so `kind load` can't run. `next build` + the standalone
// server do NOT need Docker, so this harness exercises the *application-level*
// golden path for real: per-PR basePath+SHA builds, the readiness gate, the
// SHA-gated fresh-deploy invariant across commits, multi-PR isolation, teardown,
// and timing. The k8s/ALB layer is verified separately (helm-render tests +
// cdk synth). See docs/e2e-results.md.
//
// Disk-safe: builds into the app's .next, captures the standalone bundle to a
// temp dir, then cleans .next before the next build so we never hold >1 build.
//
// Usage: node e2e/native-e2e.mjs [--keep] [scenarioFilter]
import { execFile, spawn } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtempSync, rmSync, cpSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const pexec = promisify(execFile);
const ROOT = join(fileURLToPath(import.meta.url), '..', '..');
const APP = join(ROOT, 'app');
const decide = (await import(join(ROOT, 'skills', 'preview-iterate', 'lib', 'preview-status.mjs'))).decideNextAction;

const ARGS = process.argv.slice(2); // drop node + script path
const KEEP = ARGS.includes('--keep');
const FILTER = ARGS.find((a) => !a.startsWith('--'));
let PORT = 4100;

const log = (m) => process.stderr.write(`  ${m}\n`);
const nowMs = () => Number(process.hrtime.bigint() / 1000000n);

// Build one PR's image-equivalent (standalone bundle) with baked basePath + sha.
async function buildPreview(pr, sha, { bootDelayMs = 0 } = {}) {
  const basePath = `/pr-${pr}`;
  const t0 = nowMs();
  rmSync(join(APP, '.next'), { recursive: true, force: true });
  await pexec('npm', ['run', 'build'], {
    cwd: APP,
    env: { ...process.env, PREVIEW_ROUTING_MODE: 'path', PREVIEW_BASE_PATH: basePath, GIT_SHA: sha },
    maxBuffer: 64 * 1024 * 1024,
  });
  // Assemble the runnable standalone bundle into a temp "image".
  const img = mkdtempSync(join(tmpdir(), `preview-pr${pr}-`));
  cpSync(join(APP, '.next', 'standalone'), img, { recursive: true });
  cpSync(join(APP, '.next', 'static'), join(img, '.next', 'static'), { recursive: true });
  if (existsSync(join(APP, 'public'))) cpSync(join(APP, 'public'), join(img, 'public'), { recursive: true });
  rmSync(join(APP, '.next'), { recursive: true, force: true }); // disk-safe
  return { img, basePath, bootDelayMs, buildMs: nowMs() - t0 };
}

// "Deploy": start the standalone server (a pod stand-in).
function deploy(image, pr, sha) {
  const port = PORT++;
  const proc = spawn('node', ['server.js'], {
    cwd: image.img,
    env: {
      ...process.env,
      PORT: String(port),
      BUILD_GIT_SHA: sha,
      PREVIEW_ROUTING_MODE: 'path',
      PREVIEW_BASE_PATH: image.basePath,
      PREVIEW_PR_NUMBER: String(pr),
      PREVIEW_BOOT_DELAY_MS: String(image.bootDelayMs),
    },
    stdio: 'ignore',
  });
  return { proc, port, basePath: image.basePath, img: image.img };
}

async function curlHealth(dep) {
  try {
    const { stdout } = await pexec('curl', ['-s', '-m', '4', `http://localhost:${dep.port}${dep.basePath}/api/health`]);
    return JSON.parse(stdout);
  } catch {
    return null;
  }
}

// Readiness gate: poll until health.ready && health.sha == want.
async function waitReady(dep, wantSha, timeoutMs = 30000) {
  const t0 = nowMs();
  const deadline = t0 + timeoutMs;
  while (nowMs() < deadline) {
    const h = await curlHealth(dep);
    const d = decide({ pushedSha: wantSha, check: { head_sha: wantSha, status: 'completed', conclusion: 'success' }, health: h });
    if (d.state === 'ready') return { ok: true, readyMs: nowMs() - t0, health: h };
    await new Promise((r) => setTimeout(r, 250));
  }
  return { ok: false, readyMs: nowMs() - t0 };
}

function teardown(dep) {
  try { dep.proc.kill('SIGTERM'); } catch {}
  if (!KEEP) rmSync(dep.img, { recursive: true, force: true });
}

// ---- assertions ----
let pass = 0, fail = 0;
const results = [];
function check(name, cond, extra = '') {
  if (cond) { pass++; log(`✓ ${name}${extra ? ` ${extra}` : ''}`); }
  else { fail++; log(`✗ ${name}${extra ? ` ${extra}` : ''}`); }
}
async function httpCode(url) {
  try { const { stdout } = await pexec('curl', ['-s', '-o', '/dev/null', '-w', '%{http_code}', '-m', '4', url]); return stdout.trim(); }
  catch { return '000'; }
}

// ---- scenarios ----
const scenarios = {
  // 1) Simple preview: build, deploy, ready, routing assertions.
  async simple() {
    const pr = 201, sha = 'simple01';
    const img = await buildPreview(pr, sha);
    const dep = deploy(img, pr, sha);
    try {
      const r = await waitReady(dep, sha);
      check('simple: becomes ready', r.ok);
      check('simple: health.sha matches build', r.health?.sha === sha, `(${r.health?.sha})`);
      const root404 = await httpCode(`http://localhost:${dep.port}/api/health`);
      check('simple: bare /api/health 404s (basePath active)', root404 === '404', `(${root404})`);
      const diag = await httpCode(`http://localhost:${dep.port}${dep.basePath}/diagnostics`);
      check('simple: /pr-N/diagnostics serves 200', diag === '200', `(${diag})`);
      results.push({ scenario: 'simple', pr, buildMs: img.buildMs, readyMs: r.readyMs, totalMs: img.buildMs + r.readyMs });
    } finally {
      teardown(dep);
    }
  },

  // 2) Slow-boot preview: readiness gate must not pass before boot delay.
  async slowBoot() {
    const pr = 202, sha = 'slowboot1', delay = 4000;
    const img = await buildPreview(pr, sha, { bootDelayMs: delay });
    const dep = deploy(img, pr, sha);
    try {
      // Immediately after start, health should be 503 (starting).
      await new Promise((r) => setTimeout(r, 800));
      const early = await curlHealth(dep);
      check('slowBoot: not ready during boot delay', early == null || early.ready === false, `(${early?.status})`);
      const r = await waitReady(dep, sha, 20000);
      check('slowBoot: ready after boot delay', r.ok);
      // readyMs is measured from when polling starts, which is AFTER the server
      // process already began booting (deploy() returns first), so it slightly
      // undershoots the true boot delay. Allow that measurement skew (~1s) while
      // still proving the gate held the workload back for most of the delay.
      check('slowBoot: readiness waited near delay', r.readyMs >= delay - 1000, `(${r.readyMs}ms of ${delay}ms)`);
      results.push({ scenario: 'slowBoot', pr, buildMs: img.buildMs, readyMs: r.readyMs, totalMs: img.buildMs + r.readyMs });
    } finally {
      teardown(dep);
    }
  },

  // 3) Multi-commit on one PR: the SHA-gated fresh-deploy invariant.
  async multiCommit() {
    const pr = 203;
    const sha1 = 'commitA0001111', sha2 = 'commitB0002222';
    const img1 = await buildPreview(pr, sha1);
    let dep1 = deploy(img1, pr, sha1);
    let dep2 = null;
    try {
      const r1 = await waitReady(dep1, sha1);
      check('multiCommit: commit A ready', r1.ok);

      // Agent pushed commit B. While B's build/deploy is in flight, the OLD
      // deployment (A) is still serving. The skill must NOT treat A as B.
      const staleDecision = decide({
        pushedSha: sha2,
        check: { head_sha: sha2, status: 'completed', conclusion: 'success' },
        health: r1.health, // still serving sha1
      });
      check('multiCommit: stale guard blocks testing old deploy', staleDecision.state === 'stale', `(${staleDecision.state})`);

      // Now B finishes (cancel-in-progress would have killed A's run in CI; here we
      // roll the deployment by starting B and tearing down A).
      const img2 = await buildPreview(pr, sha2);
      dep2 = deploy(img2, pr, sha2);
      const r2 = await waitReady(dep2, sha2);
      check('multiCommit: commit B ready', r2.ok);
      check('multiCommit: now serving sha2', r2.health?.sha === sha2, `(${r2.health?.sha})`);
      results.push({ scenario: 'multiCommit', pr, buildMs: img2.buildMs, readyMs: r2.readyMs, totalMs: img2.buildMs + r2.readyMs });
    } finally {
      teardown(dep1);
      if (dep2) teardown(dep2);
    }
  },

  // 4) Multi-PR isolation: two PRs serve their own basePath + SHA concurrently.
  async multiPr() {
    const a = { pr: 204, sha: 'prAAA0010001' };
    const b = { pr: 205, sha: 'prBBB0020002' };
    const imgA = await buildPreview(a.pr, a.sha);
    let depA = deploy(imgA, a.pr, a.sha);
    let depB = null;
    try {
      const rA = await waitReady(depA, a.sha);
      const imgB = await buildPreview(b.pr, b.sha);
      depB = deploy(imgB, b.pr, b.sha);
      const rB = await waitReady(depB, b.sha);
      check('multiPr: PR 204 ready on its own port/path', rA.ok && rA.health?.sha === a.sha);
      check('multiPr: PR 205 ready on its own port/path', rB.ok && rB.health?.sha === b.sha);
      check('multiPr: each serves a distinct basePath', depA.basePath !== depB.basePath, `(${depA.basePath} vs ${depB.basePath})`);
      // Cross-check: PR204 port does not serve PR205 basePath.
      const cross = await httpCode(`http://localhost:${depA.port}${depB.basePath}/api/health`);
      check('multiPr: PR204 does not serve PR205 path', cross === '404', `(${cross})`);
      results.push({ scenario: 'multiPr', pr: `${a.pr}+${b.pr}`, buildMs: imgA.buildMs + imgB.buildMs, readyMs: Math.max(rA.readyMs, rB.readyMs) });
    } finally {
      teardown(depA);
      if (depB) teardown(depB);
    }
  },
};

async function run() {
  const names = Object.keys(scenarios).filter((n) => !FILTER || n.toLowerCase().includes(FILTER.toLowerCase()));
  process.stderr.write(`\nnative-e2e: running ${names.length} scenario(s)\n`);
  for (const n of names) {
    process.stderr.write(`\n[scenario] ${n}\n`);
    try { await scenarios[n](); }
    catch (e) { fail++; log(`✗ ${n} threw: ${e.message}`); }
  }
  process.stderr.write(`\nnative-e2e: ${pass} passed, ${fail} failed\n`);
  // Emit machine-readable timing for the report step.
  console.log(JSON.stringify({ pass, fail, results }, null, 2));
  process.exit(fail === 0 ? 0 : 1);
}
run();
