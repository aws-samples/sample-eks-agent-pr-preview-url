#!/usr/bin/env node
// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
// db-isolation.mjs — proves per-PR schema isolation against a REAL
// Postgres (Aurora on EKS, or any reachable PG via DATABASE_URL).
//
// Simulates two previews (PR 42, PR 51) hitting the SAME database with their
// own PREVIEW_DB_SCHEMA, then asserts:
//   - each only sees its own preview_visits rows
//   - the schemas are physically distinct
//   - a third preview reusing PR 42's number sees PR 42's data (stable schema)
//
// Usage: DATABASE_URL=postgres://... node e2e/db-isolation.mjs
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(fileURLToPath(import.meta.url), '..', '..');

const url = process.env.DATABASE_URL;
if (!url) {
  // This is a live-DB proof — it can only run against a real Postgres. Skip
  // cleanly (exit 0) when no DATABASE_URL is set so it's safe to wire into the
  // default test run / CI (which is DB-less), while still executing when a DB is
  // provided (the with-data path). Set REQUIRE_DB=1 to make its absence a failure.
  const msg = 'db-isolation: SKIP — no DATABASE_URL (set it to run against Aurora/Postgres)';
  if (process.env.REQUIRE_DB === '1') { console.error(msg.replace('SKIP', 'FAIL')); process.exit(2); }
  console.log(msg);
  process.exit(0);
}

// Reuse the app's exact sanitizer + query path by importing the compiled module
// is overkill here; replicate the minimal contract the app uses.
const { Client } = await import(join(ROOT, 'app', 'node_modules', 'pg', 'lib', 'index.js'))
  .catch(() => import('pg'));

let pass = 0, fail = 0;
const check = (name, cond, extra = '') => {
  if (cond) { pass++; console.log(`  ✓ ${name}${extra ? ` ${extra}` : ''}`); }
  else { fail++; console.log(`  ✗ ${name}${extra ? ` ${extra}` : ''}`); }
};

// Mirror app/src/lib/runtime.ts::dbSchemaName sanitization.
const schemaFor = (pr) =>
  `pr_${pr}`.toLowerCase().replace(/[^a-z0-9_]/g, '_').replace(/^([0-9])/, '_$1').slice(0, 63);

// What the app does per preview: create schema, set search_path, ensure table,
// insert a visit, return its own rows.
async function visit(pr, sha) {
  const schema = schemaFor(pr);
  const c = new Client({ connectionString: url, connectionTimeoutMillis: 5000 });
  await c.connect();
  try {
    await c.query(`CREATE SCHEMA IF NOT EXISTS "${schema}"`);
    await c.query(`SET search_path TO "${schema}"`);
    await c.query(`CREATE TABLE IF NOT EXISTS preview_visits (id SERIAL PRIMARY KEY, pr TEXT, sha TEXT, seen_at TIMESTAMPTZ DEFAULT now())`);
    await c.query('INSERT INTO preview_visits (pr, sha) VALUES ($1,$2)', [String(pr), sha]);
    const rows = (await c.query('SELECT pr, sha FROM preview_visits ORDER BY id')).rows;
    return { schema, rows };
  } finally {
    await c.end().catch(() => {});
  }
}

async function dropSchema(pr) {
  const c = new Client({ connectionString: url, connectionTimeoutMillis: 5000 });
  await c.connect();
  try { await c.query(`DROP SCHEMA IF EXISTS "${schemaFor(pr)}" CASCADE`); }
  finally { await c.end().catch(() => {}); }
}

console.log('\ndb-isolation: proving per-PR schema isolation against real Postgres\n');
try {
  // Clean slate.
  await dropSchema(42); await dropSchema(51);

  // PR 42 visits twice, PR 51 once.
  const a1 = await visit(42, 'shaA1');
  await visit(42, 'shaA2');
  const b1 = await visit(51, 'shaB1');

  // Re-read each PR's current view.
  const a = await visit(42, 'shaA3'); // 4th row for 42
  const b = await visit(51, 'shaB2'); // 2nd row for 51

  // PR42 inserted at: a1(shaA1), visit(shaA2), a(shaA3) => 3 rows.
  // PR51 inserted at: b1(shaB1), b(shaB2) => 2 rows.
  check('PR42 and PR51 use distinct schemas', a.schema !== b.schema, `(${a.schema} vs ${b.schema})`);
  check('PR42 only sees its own rows (all pr=42)', a.rows.every((r) => r.pr === '42'), `(${a.rows.length} rows)`);
  check('PR51 only sees its own rows (all pr=51)', b.rows.every((r) => r.pr === '51'), `(${b.rows.length} rows)`);
  check('PR42 row count independent of PR51', a.rows.length === 3 && b.rows.length === 2, `(42→${a.rows.length}, 51→${b.rows.length})`);
  check('no PR51 sha leaked into PR42 view', !a.rows.some((r) => String(r.sha).startsWith('shaB')));

  // Stability: a new pod for PR 42 (same number) sees PR 42's accumulated data.
  const a2 = await visit(42, 'shaA4'); // PR42's 4th insert
  check('reusing PR42 number sees prior PR42 data (stable schema)', a2.rows.length === 4);

  // Teardown drops the schema: after DROP, it must be gone.
  await dropSchema(42);
  const c = new Client({ connectionString: url, connectionTimeoutMillis: 5000 });
  await c.connect();
  const exists = (await c.query(
    'SELECT 1 FROM information_schema.schemata WHERE schema_name=$1', [schemaFor(42)],
  )).rowCount;
  await c.end().catch(() => {});
  check('teardown DROP removes the PR schema', exists === 0, `(${schemaFor(42)} present=${exists})`);

  // Cleanup.
  await dropSchema(51);
} catch (e) {
  fail++; console.log(`  ✗ threw: ${e.message}`);
}

console.log(`\ndb-isolation: ${pass} passed, ${fail} failed\n`);
process.exit(fail === 0 ? 0 : 1);
