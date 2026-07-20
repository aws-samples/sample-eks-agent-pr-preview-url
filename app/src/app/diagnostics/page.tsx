// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import { getRuntimeInfo, checkDatabase } from '@/lib/runtime';
import { headers } from 'next/headers';

// The diagnostic page must reflect live state — never statically cached.
export const dynamic = 'force-dynamic';

const card: React.CSSProperties = {
  border: '1px solid #2a2f3a',
  borderRadius: 12,
  background: '#161922',
  padding: 18,
  marginBottom: 16,
};
const label: React.CSSProperties = { color: '#9aa1ad', fontSize: 13 };
const mono: React.CSSProperties = {
  fontFamily: 'ui-monospace, "SF Mono", Menlo, monospace',
  fontSize: 13,
};

function Badge({ ok, children }: { ok: boolean; children: React.ReactNode }) {
  return (
    <span
      style={{
        ...mono,
        padding: '2px 9px',
        borderRadius: 999,
        background: ok ? 'rgba(120,180,90,0.16)' : 'rgba(217,90,90,0.16)',
        color: ok ? '#9ada73' : '#ff8585',
        border: `1px solid ${ok ? '#4f7a3a' : '#7a3a3a'}`,
      }}
    >
      {children}
    </span>
  );
}

/**
 * Diagnostic / debug page (requested in the goal) — a single screen that makes
 * a Preview Environment's runtime state legible for humans AND for e2e tests.
 * Every field carries a data-testid so Playwright can assert on it.
 */
export default async function Diagnostics() {
  const info = getRuntimeInfo();
  const db = await checkDatabase();
  const hdrs = await headers();
  const interestingHeaders = [
    'host',
    'x-forwarded-host',
    'x-forwarded-proto',
    'x-forwarded-for',
    'user-agent',
  ];

  return (
    <main style={{ maxWidth: 820, margin: '0 auto', padding: '48px 24px' }}>
      <h1 style={{ fontSize: 26, marginBottom: 4 }}>Diagnostics</h1>
      <p style={{ color: '#9aa1ad', marginBottom: 24 }}>
        Live runtime state for this Preview Environment.
      </p>

      <section style={card}>
        <h2 style={{ fontSize: 16, marginBottom: 12 }}>Build &amp; routing</h2>
        <Row k="Build SHA" testid="diag-sha" v={info.buildSha} />
        <Row k="Routing mode" testid="diag-routing-mode" v={info.routingMode} />
        <Row k="basePath" testid="diag-basepath" v={info.basePath || '(none)'} />
        <Row k="PR number" testid="diag-pr" v={info.prNumber ?? '(n/a)'} />
        <Row k="NODE_ENV" testid="diag-node-env" v={info.nodeEnv} />
        <Row k="Started at" testid="diag-started" v={info.startedAt} />
      </section>

      <section style={card}>
        <h2 style={{ fontSize: 16, marginBottom: 12 }}>
          Shared sandbox backend (Aurora){' '}
          <Badge ok={db.ok}>{db.configured ? (db.ok ? 'connected' : 'error') : 'unconfigured'}</Badge>
        </h2>
        <Row k="Configured" testid="diag-db-configured" v={String(db.configured)} />
        <Row k="OK" testid="diag-db-ok" v={String(db.ok)} />
        <Row k="Detail" testid="diag-db-detail" v={db.detail} />
        <Row k="Server" testid="diag-db-version" v={db.serverVersion ?? '(n/a)'} />
        <Row k="Schema (PR-isolated)" testid="diag-db-schema" v={db.schema} />
        <Row k="Latency" testid="diag-db-latency" v={db.latencyMs == null ? '(n/a)' : `${db.latencyMs}ms`} />
        <Row k="Total visits (this schema)" testid="diag-db-total" v={db.totalVisits == null ? '(n/a)' : String(db.totalVisits)} />
      </section>

      {db.ok && (
        <section style={card}>
          <h2 style={{ fontSize: 16, marginBottom: 4 }}>Live data from the database</h2>
          <p style={{ ...label, marginBottom: 12 }}>
            Each load INSERTs a <code style={mono}>preview_visits</code> row, then SELECTs the
            latest 5 back — a real write+read round-trip against the shared sandbox.
          </p>
          <table style={{ width: '100%', borderCollapse: 'collapse', ...mono }} data-testid="diag-db-visits">
            <thead>
              <tr style={{ textAlign: 'left', color: '#9aa1ad' }}>
                <th style={{ padding: '4px 8px' }}>id</th>
                <th style={{ padding: '4px 8px' }}>pr</th>
                <th style={{ padding: '4px 8px' }}>sha</th>
                <th style={{ padding: '4px 8px' }}>seen_at</th>
              </tr>
            </thead>
            <tbody>
              {db.visits.map((v) => (
                <tr key={v.id} style={{ borderTop: '1px solid #21262f' }}>
                  <td style={{ padding: '4px 8px' }}>{v.id}</td>
                  <td style={{ padding: '4px 8px' }}>{v.pr ?? '—'}</td>
                  <td style={{ padding: '4px 8px' }}>{v.sha ?? '—'}</td>
                  <td style={{ padding: '4px 8px' }}>{v.seenAt}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>
      )}

      <section style={card}>
        <h2 style={{ fontSize: 16, marginBottom: 12 }}>Request headers</h2>
        {interestingHeaders.map((h) => (
          <Row key={h} k={h} v={hdrs.get(h) ?? '(absent)'} />
        ))}
      </section>

      <p style={{ ...mono, color: '#6b7280' }}>
        GET <code>/api/health</code> for the machine-readable version the agent loop consumes.
      </p>
    </main>
  );
}

function Row({ k, v, testid }: { k: string; v: string; testid?: string }) {
  return (
    <div
      style={{
        display: 'grid',
        gridTemplateColumns: '180px 1fr',
        gap: 10,
        padding: '5px 0',
        borderBottom: '1px solid #21262f',
      }}
    >
      <span style={label}>{k}</span>
      <span style={mono} data-testid={testid}>
        {v}
      </span>
    </div>
  );
}