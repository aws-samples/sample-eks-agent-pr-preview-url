// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
/**
 * Runtime introspection shared by the health endpoint and the diagnostic page.
 * Kept dependency-light and pure so it is trivially unit-testable.
 */
import { log } from './logger';

export interface RuntimeInfo {
  service: string;
  buildSha: string;
  routingMode: string;
  basePath: string;
  prNumber: string | null;
  dbSchema: string;
  nodeEnv: string;
  startedAt: string;
}

/**
 * Per-PR Postgres schema name. Each Preview Environment scopes its data to its
 * own schema within the shared Aurora cluster via `search_path`, keeping
 * well-behaved app queries from colliding across PRs. NOTE: this is a
 * *convenience* separation, not a security boundary — all previews share one DB
 * user, so PR-authored (untrusted) code could fully-qualify another PR's schema.
 * For mutually-untrusting tenants use per-PR DB roles / databases (see
 * SECURITY.md). Derived from the PR number; falls back to a safe default when
 * unknown. Sanitized to a valid, injection-safe identifier.
 */
export function dbSchemaName(): string {
  const explicit = process.env.PREVIEW_DB_SCHEMA;
  const pr = process.env.PREVIEW_PR_NUMBER;
  const raw = explicit && explicit.length > 0 ? explicit : pr ? `pr_${pr}` : 'preview';
  // Postgres identifiers: lowercase, start with letter/underscore, [a-z0-9_].
  const safe = raw.toLowerCase().replace(/[^a-z0-9_]/g, '_').replace(/^([0-9])/, '_$1');
  return safe.slice(0, 63) || 'preview';
}

const STARTED_AT = new Date().toISOString();

export function getRuntimeInfo(): RuntimeInfo {
  const basePath = process.env.PREVIEW_BASE_PATH ?? '';
  // pr number is derivable from basePath (/pr-123) or from an explicit env var.
  const fromBasePath = /\/pr-(\d+)/.exec(basePath)?.[1] ?? null;
  const prNumber = process.env.PREVIEW_PR_NUMBER ?? fromBasePath;

  return {
    service: 'pr-preview-reference-workload',
    buildSha: process.env.BUILD_GIT_SHA ?? 'dev-local',
    routingMode: process.env.PREVIEW_ROUTING_MODE ?? 'host',
    basePath,
    prNumber,
    dbSchema: dbSchemaName(),
    nodeEnv: process.env.NODE_ENV ?? 'development',
    startedAt: STARTED_AT,
  };
}

export interface DbVisit {
  id: number;
  pr: string | null;
  sha: string | null;
  seenAt: string;
}

export interface DbCheck {
  configured: boolean;
  ok: boolean;
  detail: string;
  latencyMs: number | null;
  serverVersion: string | null;
  schema: string;
  // Rows read back from this PR's OWN schema to prove a real round-trip.
  visits: DbVisit[];
  totalVisits: number | null;
}

const EMPTY_DB = (configured: boolean, detail: string): DbCheck => ({
  configured,
  ok: false,
  detail,
  latencyMs: null,
  serverVersion: null,
  schema: dbSchemaName(),
  visits: [],
  totalVisits: null,
});

/**
 * Exercises the shared sandbox backend with a REAL round-trip, not just a ping:
 *   1. connect + read server version
 *   2. ensure a demo table exists
 *   3. INSERT a row recording this preview "visit" (pr + sha)
 *   4. SELECT the most recent visits back and a total count
 * Returns the rows so the diagnostic page can DISPLAY live data from the DB.
 *
 * Never throws — returns a structured result. Short timeout so a misconfigured
 * DB cannot hang the page or readiness checks. Always closes the client.
 */
export async function checkDatabase(timeoutMs = 2500): Promise<DbCheck> {
  const url = process.env.DATABASE_URL;
  if (!url) return EMPTY_DB(false, 'DATABASE_URL not set');

  const info = getRuntimeInfo();
  const schema = dbSchemaName(); // already sanitized to a safe identifier
  const start = Date.now();
  const { Client } = await import('pg');
  const client = new Client({ connectionString: url, connectionTimeoutMillis: timeoutMs });
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(`timeout after ${timeoutMs}ms`)), timeoutMs);
  });
  const race = <T>(p: Promise<T>) => Promise.race([p, timeout]);

  try {
    await race(client.connect());

    const ver = await race(client.query<{ v: string }>('SELECT version() AS v'));
    const serverVersion = ver.rows[0]?.v?.split(',')[0] ?? null;

    // Per-PR schema scoping: each preview's queries default to its OWN schema in
    // the shared cluster (a convenience separation, NOT a security boundary — all
    // previews share one DB user; see dbSchemaName() + SECURITY.md). `schema` is a
    // pre-sanitized identifier (validated in dbSchemaName), so interpolating it
    // is safe — schema/table names cannot be bound as query parameters.
    await race(client.query(`CREATE SCHEMA IF NOT EXISTS "${schema}"`));
    await race(client.query(`SET search_path TO "${schema}"`));
    await race(
      client.query(`
        CREATE TABLE IF NOT EXISTS preview_visits (
          id        SERIAL PRIMARY KEY,
          pr        TEXT,
          sha       TEXT,
          seen_at   TIMESTAMPTZ NOT NULL DEFAULT now()
        )`),
    );
    await race(
      client.query('INSERT INTO preview_visits (pr, sha) VALUES ($1, $2)', [
        info.prNumber,
        info.buildSha,
      ]),
    );

    const recent = await race(
      client.query<{ id: number; pr: string | null; sha: string | null; seen_at: Date }>(
        'SELECT id, pr, sha, seen_at FROM preview_visits ORDER BY id DESC LIMIT 5',
      ),
    );
    const count = await race(client.query<{ c: string }>('SELECT count(*)::int AS c FROM preview_visits'));

    return {
      configured: true,
      ok: true,
      detail: `connected · schema "${schema}" · query round-trip ok`,
      latencyMs: Date.now() - start,
      serverVersion,
      schema,
      visits: recent.rows.map((r) => ({
        id: r.id,
        pr: r.pr,
        sha: r.sha,
        seenAt: new Date(r.seen_at).toISOString(),
      })),
      totalVisits: Number(count.rows[0]?.c ?? 0),
    };
  } catch (err) {
    // /diagnostics is public by default, so never surface the raw driver message
    // (it can embed the DB host/IP/user). Log the full error server-side and
    // return only a generic detail + the short error code for operator triage.
    const full = err instanceof Error ? err.message : String(err);
    const code = (err as { code?: string })?.code;
    log.error('db check failed', { code, error: full });
    const r = EMPTY_DB(true, `database connection failed${code ? ` (${code})` : ''}`);
    return { ...r, latencyMs: Date.now() - start };
  } finally {
    if (timer) clearTimeout(timer);
    await client.end().catch(() => {});
  }
}

/**
 * Optional artificial boot delay, used by the e2e harness to simulate
 * slow-booting workloads and exercise the readiness gate. Off by default.
 */
export function bootDelayMs(): number {
  const v = Number.parseInt(process.env.PREVIEW_BOOT_DELAY_MS ?? '0', 10);
  return Number.isFinite(v) && v > 0 ? v : 0;
}