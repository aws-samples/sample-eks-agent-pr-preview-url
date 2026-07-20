#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# preview-lib.sh — shared deploy/readiness/teardown logic for the preview platform.
#
# Used by both the local kind harness (scripts/preview-local.sh) and conceptually
# mirrors what the reusable GitHub Actions workflow does on EKS. Keeping the logic
# here means the golden path is exercised identically locally and in CI.
#
# Routing: path mode. PR -> namespace pr-<n>, served at /pr-<n>/.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART="$ROOT/charts/preview-env"
RELEASE="web"
INGRESS_CLASS="${INGRESS_CLASS:-nginx}"
PREVIEW_HOST_BASE="${PREVIEW_HOST_BASE:-http://localhost:8080}"
IMAGE_REPO="${IMAGE_REPO:-pr-preview/app}"

log()  { printf '\033[36m[preview]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[31m[preview:err]\033[0m %s\n' "$*" >&2; }

ns_for()   { echo "pr-$1"; }
basepath() { echo "/pr-$1"; }

# now_ms — millisecond epoch, portable across macOS/Linux without python3.
# GNU date supports %N; macOS/BSD date does not, so fall back to perl, then to
# second-granularity *1000 as a last resort (never empty → no silent 0ms math).
now_ms() {
  local ms
  ms="$(date +%s%3N 2>/dev/null)"
  if [[ "$ms" == *N* || -z "$ms" ]]; then
    ms="$(perl -MTime::HiRes=time -e 'printf("%d", time()*1000)' 2>/dev/null)"
  fi
  [[ -n "$ms" ]] || ms="$(( $(date +%s) * 1000 ))"
  echo "$ms"
}

# build_image <pr> <sha> [boot_delay_ms]
# Builds the path-mode (basePath-baked) image and loads it into kind.
build_image() {
  local pr="$1" sha="$2" delay="${3:-0}" tag
  tag="sha-${sha}"
  local img="${IMAGE_REPO}:${tag}"
  log "build image $img (pr=$pr basePath=$(basepath "$pr"))"
  DOCKER_BUILDKIT=1 docker build \
    --build-arg GIT_SHA="$sha" \
    --build-arg PREVIEW_ROUTING_MODE=path \
    --build-arg PREVIEW_BASE_PATH="$(basepath "$pr")" \
    -t "$img" "$ROOT/app" >&2 || { err "docker build failed"; return 1; }
  if command -v kind >/dev/null 2>&1; then
    log "loading $img into kind"
    kind load docker-image "$img" --name pr-preview >&2 || { err "kind load failed"; return 1; }
  fi
  echo "$tag"
}

# deploy <pr> <tag> [boot_delay_ms]
deploy() {
  local pr="$1" tag="$2" delay="${3:-0}" ns
  ns="$(ns_for "$pr")"
  log "helm upgrade --install $RELEASE -n $ns (tag=$tag)"
  # Ensure the namespace carries the platform label so the teardown sweep
  # (which selects namespaces, not workloads) can find it. --create-namespace
  # makes a bare, unlabeled namespace, so label it explicitly.
  kubectl create namespace "$ns" --dry-run=client -o yaml 2>/dev/null | kubectl apply -f - >/dev/null 2>&1 || true
  kubectl label namespace "$ns" app.kubernetes.io/part-of=preview-platform \
    "preview.pr-preview/pr-number=$pr" --overwrite >/dev/null 2>&1 || true
  helm upgrade --install "$RELEASE" "$CHART" \
    --namespace "$ns" --create-namespace \
    --set prNumber="$pr" \
    --set routing.mode=path \
    --set routing.ingressClassName="$INGRESS_CLASS" \
    --set image.repository="$IMAGE_REPO" \
    --set image.tag="$tag" \
    --set image.pullPolicy=IfNotPresent \
    --set bootDelayMs="$delay" \
    --wait --timeout 120s >&2
}

# preview_url <pr>
preview_url() { echo "${PREVIEW_HOST_BASE}$(basepath "$1")"; }

# wait_ready <pr> <expected_sha> [timeout_sec]
# The readiness gate: poll the REAL url through the ingress until
# /api/health returns 200 AND its sha == expected. Returns 0 on success.
wait_ready() {
  local pr="$1" want="$2" timeout="${3:-90}" url code body got
  url="$(preview_url "$pr")/api/health"
  local deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    body="$(curl -s -m 4 -w '\n%{http_code}' "$url" 2>/dev/null)"
    code="$(printf '%s' "$body" | tail -1)"
    if [ "$code" = "200" ]; then
      got="$(printf '%s' "$body" | sed '$d' | jq -r '.sha // empty' 2>/dev/null)"
      if [ "$got" = "$want" ]; then
        log "ready: $url serving sha=$got"
        return 0
      fi
      log "url up but sha=$got != want=$want (stale, waiting)"
    fi
    sleep 2
  done
  err "timeout waiting for $url to serve sha=$want"
  return 1
}

# diagnose <pr> — emit a structured failure reason (the Check Run output field).
diagnose() {
  local pr="$1" ns; ns="$(ns_for "$pr")"
  local pods; pods="$(kubectl get pods -n "$ns" -o json 2>/dev/null)"
  local reason
  reason="$(printf '%s' "$pods" | jq -r '
    [.items[].status.containerStatuses[]?.state.waiting.reason] |
    map(select(. != null)) | (.[0] // empty)' 2>/dev/null)"
  if [ -n "$reason" ]; then echo "$reason"; return; fi
  local notready
  notready="$(printf '%s' "$pods" | jq -r '
    [.items[] | select(any(.status.conditions[]?; .type=="Ready" and .status!="True"))] | length' 2>/dev/null)"
  if [ "${notready:-0}" -gt 0 ]; then echo "HealthCheckFailed"; else echo "RoutingNotReady"; fi
}

# teardown <pr>
teardown() {
  local pr="$1" ns; ns="$(ns_for "$pr")"
  log "teardown pr-$pr"
  helm uninstall "$RELEASE" -n "$ns" >/dev/null 2>&1 || true
  kubectl delete namespace "$ns" --wait=false >/dev/null 2>&1 || true
}

# sweep <open_pr_csv> — teardown backstop: delete preview namespaces
# whose PR is not in the open set. ONLY considers namespaces labelled as
# preview-platform, so a coincidentally-named foreign ns is never deleted.
sweep() {
  local open="${1:-}"
  local names
  names="$(kubectl get ns -l app.kubernetes.io/part-of=preview-platform \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep -E '^pr-[0-9]+$' | sort -u)"
  for ns in $names; do
    local n="${ns#pr-}"
    if [[ ",$open," != *",$n,"* ]]; then
      log "sweep: pr-$n not in open set -> teardown"
      teardown "$n"
    fi
  done
}
