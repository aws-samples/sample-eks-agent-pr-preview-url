#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# preview-local.sh — CLI to drive a Preview Environment on the local kind cluster.
# Mirrors the reusable workflow's deploy/teardown, locally and measurably.
#
# Usage:
#   scripts/preview-local.sh up   <pr> <sha> [boot_delay_ms]   # build + deploy + wait-ready
#   scripts/preview-local.sh url  <pr>
#   scripts/preview-local.sh down <pr>
#   scripts/preview-local.sh sweep <open_pr_csv>
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/preview-lib.sh"

cmd="${1:-}"; shift || true
case "$cmd" in
  up)
    pr="$1"; sha="$2"; delay="${3:-0}"
    t0="$(now_ms)"
    tag="$(build_image "$pr" "$sha" "$delay")" || exit 1
    t1="$(now_ms)"
    deploy "$pr" "$tag" "$delay" || { err "deploy failed: $(diagnose "$pr")"; exit 1; }
    t2="$(now_ms)"
    if wait_ready "$pr" "$sha" 120; then
      t3="$(now_ms)"
      log "URL: $(preview_url "$pr")"
      printf 'TIMING pr=%s build_ms=%s deploy_ms=%s ready_ms=%s total_ms=%s\n' \
        "$pr" "$((t1-t0))" "$((t2-t1))" "$((t3-t2))" "$((t3-t0))"
    else
      err "readiness failed: $(diagnose "$pr")"; exit 1
    fi
    ;;
  url)   preview_url "$1" ;;
  down)  teardown "$1" ;;
  sweep) sweep "${1:-}" ;;
  *) echo "usage: $0 {up|url|down|sweep} ..." >&2; exit 2 ;;
esac
