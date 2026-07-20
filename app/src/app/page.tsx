// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import Link from 'next/link';
import { getRuntimeInfo } from '@/lib/runtime';

export const dynamic = 'force-dynamic';

export default function Home() {
  const info = getRuntimeInfo();
  return (
    <main style={{ maxWidth: 760, margin: '0 auto', padding: '64px 24px' }}>
      <h1 style={{ fontSize: 30, marginBottom: 8 }}>pr-preview</h1>
      <p style={{ color: '#9aa1ad', marginBottom: 28 }}>
        Reference workload — this is the app a Pull Request previews.
      </p>
      <div
        style={{
          display: 'grid',
          gridTemplateColumns: '1fr 1fr',
          gap: 12,
          padding: 18,
          border: '1px solid #2a2f3a',
          borderRadius: 12,
          background: '#161922',
          fontSize: 14,
        }}
      >
        <span style={{ color: '#9aa1ad' }}>Build SHA</span>
        <code data-testid="home-sha">{info.buildSha}</code>
        <span style={{ color: '#9aa1ad' }}>Routing mode</span>
        <code>{info.routingMode}</code>
        <span style={{ color: '#9aa1ad' }}>basePath</span>
        <code>{info.basePath || '(none)'}</code>
        <span style={{ color: '#9aa1ad' }}>PR number</span>
        <code>{info.prNumber ?? '(n/a)'}</code>
      </div>
      <p style={{ marginTop: 28 }}>
        <Link href="/diagnostics" style={{ color: '#5b9dff' }}>
          → Open the diagnostic / debug page
        </Link>
      </p>
    </main>
  );
}