#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# Readiness gate for the reusable workflow.
# Polls the real preview URL until /api/health returns 200 AND health.sha == WANT_SHA.
# Emits `url`, and on failure a structured `failure_reason`, to $GITHUB_OUTPUT.
set -uo pipefail

PR="${PR:?}"
ROUTING_MODE="${ROUTING_MODE:-path}"
WANT_SHA="${WANT_SHA:?}"
TIMEOUT="${READY_TIMEOUT:-240}"
NS="${NS:-pr-${PR}}"

emit() { [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1=$2" >> "$GITHUB_OUTPUT"; }
# Always emit a reason on early exit so the failure handler is never blank.
fail_reason="ConfigError"
emit failure_reason "$fail_reason"

# LOCAL_VERIFY=1 (host mode, no public domain): pin the preview host to a current
# ALB IP with `curl --resolve` and tolerate a non-public cert with `-k`, so
# host-mode routing is verifiable in an environment that forbids a public zone
# (see docs/host-mode.md). With a real public domain, leave LOCAL_VERIFY unset.
CURL_RESOLVE=()
if [ "$ROUTING_MODE" = "host" ]; then
  base="https://pr-${PR}.${BASE_DOMAIN:?BASE_DOMAIN required in host mode}"
  if [ "${LOCAL_VERIFY:-0}" = "1" ]; then
    alb="$(kubectl get ingress web -n "$NS" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)"
    alb_ip="$(dig +short "$alb" 2>/dev/null | grep -E '^[0-9.]+$' | head -1)"
    if [ -n "$alb_ip" ]; then
      CURL_RESOLVE=(-k --resolve "pr-${PR}.${BASE_DOMAIN}:443:${alb_ip}")
      echo "LOCAL_VERIFY: pinning pr-${PR}.${BASE_DOMAIN} -> ${alb_ip} (self-signed TLS tolerated)"
    fi
  fi
else
  # path mode: prefer an explicit base, else auto-discover the shared ALB
  # hostname from the Ingress this release created (so the default config works).
  host_base="${INGRESS_HOST_BASE:-}"
  if [ -z "$host_base" ]; then
    for _ in $(seq 1 30); do
      addr="$(kubectl get ingress web -n "$NS" \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)"
      [ -n "$addr" ] && { host_base="http://${addr}"; break; }
      sleep 4
    done
  fi
  if [ -z "$host_base" ]; then
    emit failure_reason "RoutingNotReady"
    echo "FAILED: could not resolve ingress address for $NS"
    exit 1
  fi
  base="${host_base}/pr-${PR}"
fi

health="${base}/api/health"
emit url "$base"

echo "Polling $health for sha=$WANT_SHA (timeout ${TIMEOUT}s)"
poll_start=$(date +%s)
deadline=$(( poll_start + TIMEOUT ))
last_code="000"
while [ "$(date +%s)" -lt "$deadline" ]; do
  resp="$(curl -s -m 5 "${CURL_RESOLVE[@]}" -w '\n%{http_code}' "$health" 2>/dev/null)"
  last_code="$(printf '%s' "$resp" | tail -1)"
  if [ "$last_code" = "200" ]; then
    got="$(printf '%s' "$resp" | sed '$d' | jq -r '.sha // empty' 2>/dev/null)"
    if [ "$got" = "$WANT_SHA" ]; then
      ready_secs=$(( $(date +%s) - poll_start ))
      echo "READY: $health serving sha=$got"
      # Deploy-time metric: structured line + Check Run field, so
      # time-to-ready is captured per deploy rather than only measured by hand.
      echo "METRIC time_to_ready_seconds=${ready_secs} pr=${PR} sha=${WANT_SHA} routing=${ROUTING_MODE}"
      emit time_to_ready_seconds "$ready_secs"
      exit 0
    fi
    echo "up but sha=$got != want=$WANT_SHA (stale)"
  fi
  sleep 4
done

# Classify the failure for the Check Run's structured reason.
if [ "$last_code" = "000" ]; then
  emit failure_reason "RoutingNotReady"
elif [ "$last_code" = "503" ]; then
  emit failure_reason "HealthCheckFailed"
else
  emit failure_reason "ReadinessTimeout"
fi
echo "FAILED: last_code=$last_code"
exit 1
