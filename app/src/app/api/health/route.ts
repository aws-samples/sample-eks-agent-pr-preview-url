// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import { NextResponse } from 'next/server';
import { getRuntimeInfo, bootDelayMs } from '@/lib/runtime';
import { log } from '@/lib/logger';

// Always dynamic — health must reflect live process state, never be cached.
export const dynamic = 'force-dynamic';

let bootGateResolved = false;
const bootGate = (async () => {
  const delay = bootDelayMs();
  if (delay > 0) await new Promise((r) => setTimeout(r, delay));
  bootGateResolved = true;
})();

/**
 * Liveness + readiness + the fresh-deploy invariant.
 *
 * The Preview Skill curls this and compares `sha` against the commit it pushed,
 * so the agent never validates a stale deployment. `ready` stays false until the
 * (optional) simulated boot delay elapses, exercising the readiness gate.
 */
export async function GET() {
  const info = getRuntimeInfo();
  if (!bootGateResolved) {
    // Touch the gate so it starts; report not-ready until it resolves.
    void bootGate;
    return NextResponse.json(
      { status: 'starting', ready: false, sha: info.buildSha },
      { status: 503 },
    );
  }

  const uptimeSec = Math.round(process.uptime());
  log.info('health.ok', { route: '/api/health', uptimeSec });
  return NextResponse.json({
    status: 'ok',
    ready: true,
    // `sha` is the contract field the agent loop gates on.
    sha: info.buildSha,
    service: info.service,
    routingMode: info.routingMode,
    basePath: info.basePath,
    prNumber: info.prNumber,
    uptimeSec,
  });
}