// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
/**
 * Next.js config for the reference workload.
 *
 * Routing modes:
 *   - host mode: app served at "/", no basePath. Set PREVIEW_ROUTING_MODE=host (or leave unset).
 *   - path mode: app served under /pr-<n>, basePath + assetPrefix baked at build time.
 *       Set PREVIEW_ROUTING_MODE=path and PREVIEW_BASE_PATH=/pr-<n>.
 *
 * basePath MUST be baked at build time — this is why the image is PR-specific in path mode.
 */
const routingMode = process.env.PREVIEW_ROUTING_MODE ?? 'host';
const rawBasePath = process.env.PREVIEW_BASE_PATH ?? '';

// Only apply basePath in path mode, and only when it's a non-root, well-formed prefix.
const basePath =
  routingMode === 'path' && rawBasePath && rawBasePath !== '/' && rawBasePath.startsWith('/')
    ? rawBasePath.replace(/\/$/, '')
    : '';

/** @type {import('next').NextConfig} */
const nextConfig = {
  output: 'standalone',
  // Surface config to the server bundle for the diagnostic page / health endpoint.
  env: {
    PREVIEW_ROUTING_MODE: routingMode,
    PREVIEW_BASE_PATH: basePath,
    // GIT_SHA is the fresh-deploy invariant signal. Baked at build.
    BUILD_GIT_SHA: process.env.GIT_SHA ?? 'dev-local',
  },
  ...(basePath ? { basePath, assetPrefix: basePath } : {}),
  // Reachability behind a proxy/ALB.
  poweredByHeader: false,
};

export default nextConfig;