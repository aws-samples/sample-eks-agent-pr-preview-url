// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
// Optional HTTP Basic Auth for preview environments.
//
// Enabled by setting BASIC_AUTH_B64 to base64("user:pass"). When unset (the
// default), every request passes through — public-by-default is preserved.
//
// `/api/health` is ALWAYS exempt (see lib/basic-auth): the platform's readiness
// gate and the deploy workflow poll it without credentials, and it exposes only
// liveness + the build SHA. This keeps the SHA-gated fresh-deploy invariant
// working while the rest of the preview is password-walled.
import { NextRequest, NextResponse } from 'next/server';
import { isAuthorized } from './lib/basic-auth';

const EXPECTED = process.env.BASIC_AUTH_B64 ?? '';

export function middleware(req: NextRequest): NextResponse {
  if (isAuthorized(EXPECTED, req.headers.get('authorization'), req.nextUrl.pathname)) {
    return NextResponse.next();
  }
  return new NextResponse('Authentication required', {
    status: 401,
    headers: { 'WWW-Authenticate': 'Basic realm="preview", charset="UTF-8"' },
  });
}

// Run on everything except Next.js internals and static assets. The explicit
// '/' entry ensures the index route is gated too — the negative-lookahead
// pattern alone can skip the bare root (and with basePath, Next strips the
// prefix so the home page arrives as '/').
export const config = {
  matcher: ['/', '/((?!_next/static|_next/image|favicon.ico).*)'],
};