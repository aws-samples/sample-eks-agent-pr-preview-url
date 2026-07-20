#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# verify-host-mode.sh — prove host-mode routing works with NO public DNS.
#
# AWS ALB host-based routing matches on the HTTP Host header, not on DNS. So a
# preview deployed in host mode (pr-<n>.<baseDomain>) is verifiable with zero
# public domain: point curl at the shared ALB and send the right Host header.
# See docs/host-mode.md for the full rationale + the public-domain path.
#
# Usage:  ./scripts/verify-host-mode.sh <pr-number> [base-domain]
set -euo pipefail
PR="${1:?usage: verify-host-mode.sh <pr-number> [base-domain]}"
BASE_DOMAIN="${2:-preview.example.com}"
HOST="pr-${PR}.${BASE_DOMAIN}"
NS="pr-${PR}"

# 1. Discover the shared ALB hostname the Ingress was assigned.
ALB="$(kubectl get ingress web -n "$NS" \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
[ -n "$ALB" ] || { echo "no ALB hostname yet for $NS"; exit 1; }

# 2. Resolve ONE current ALB IP (the ALB is a rotating hostname, not a fixed IP).
ALB_IP="$(dig +short "$ALB" | grep -E '^[0-9.]+$' | head -1)"
[ -n "$ALB_IP" ] || { echo "could not resolve $ALB"; exit 1; }
echo "ALB=$ALB  IP=$ALB_IP  HOST=$HOST"

# 3a. HTTP-only proof of the host rule (no cert needed) — the minimal bar.
echo "== HTTP host-rule check =="
curl -fsS -H "Host: ${HOST}" "http://${ALB}/api/health" | jq .

# 3b. HTTPS proof through the real TLS + SNI + host path (-k tolerates a
#     self-signed / name-mismatched cert; a publicly trusted cert needs a public
#     domain — see docs/host-mode.md).
echo "== HTTPS (SNI + host) check =="
curl -fsSk --resolve "${HOST}:443:${ALB_IP}" "https://${HOST}/api/health" | jq . \
  || echo "(HTTPS skipped/failed — expected if no TLS listener is configured)"
