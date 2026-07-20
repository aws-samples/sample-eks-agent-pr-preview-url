# syntax=docker/dockerfile:1.7
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# Multi-stage build for the Next.js reference workload (output: 'standalone').
#
# Build args:
#   GIT_SHA              — baked into the image; surfaced by /api/health (fresh-deploy invariant)
#   PREVIEW_ROUTING_MODE — host | path
#   PREVIEW_BASE_PATH    — /pr-<n> in path mode (bakes Next.js basePath → PR-specific image)

# ---- deps: install node_modules from lockfile (cacheable across PRs) ----
FROM node:22-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json* ./
RUN --mount=type=cache,target=/root/.npm \
    npm ci --no-audit --no-fund

# ---- builder: next build (basePath baked here in path mode) ----
FROM node:22-alpine AS builder
WORKDIR /app
ARG GIT_SHA=dev-local
ARG PREVIEW_ROUTING_MODE=host
ARG PREVIEW_BASE_PATH=
ENV GIT_SHA=$GIT_SHA \
    PREVIEW_ROUTING_MODE=$PREVIEW_ROUTING_MODE \
    PREVIEW_BASE_PATH=$PREVIEW_BASE_PATH \
    NEXT_TELEMETRY_DISABLED=1
COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN npm run build

# ---- runner: minimal standalone runtime, non-root ----
FROM node:22-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=3000 \
    HOSTNAME=0.0.0.0
# Carry build-time identity into the running process for /api/health.
ARG GIT_SHA=dev-local
ARG PREVIEW_ROUTING_MODE=host
ARG PREVIEW_BASE_PATH=
ENV BUILD_GIT_SHA=$GIT_SHA \
    PREVIEW_ROUTING_MODE=$PREVIEW_ROUTING_MODE \
    PREVIEW_BASE_PATH=$PREVIEW_BASE_PATH

# Run as the built-in non-root `node` user.
RUN chown -R node:node /app
USER node

# standalone output: server.js + minimal node_modules, plus static + public.
COPY --chown=node:node --from=builder /app/.next/standalone ./
COPY --chown=node:node --from=builder /app/.next/static ./.next/static
COPY --chown=node:node --from=builder /app/public ./public

EXPOSE 3000

# Container-level liveness (k8s uses its own probes; this helps `docker`/compose
# and satisfies image scanners). Hits the app's own health endpoint at its basePath.
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||3000)+(process.env.PREVIEW_BASE_PATH||'')+'/api/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "server.js"]