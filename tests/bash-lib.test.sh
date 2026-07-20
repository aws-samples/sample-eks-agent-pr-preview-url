#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# Unit tests for the bash deploy library's pure functions (Phase 0).
# No cluster, no docker — sources the lib and exercises logic only. Runnable on
# macOS bash 3.2 and Linux bash 5. Run: bash tests/bash-lib.test.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

pass=0; fail=0
ok()  { if [ "$2" = "$3" ]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 — got [$2] want [$3]"; fail=$((fail+1)); fi; }
okm() { if grep -qE "$3" <<<"$2"; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 — [$2] !~ /$3/"; fail=$((fail+1)); fi; }

# shellcheck disable=SC1090
source "$ROOT/scripts/preview-lib.sh"

echo "preview-lib naming:"
ok "ns_for 7"        "$(ns_for 7)"        "pr-7"
ok "ns_for 123"      "$(ns_for 123)"      "pr-123"
ok "basepath 7"      "$(basepath 7)"      "/pr-7"
ok "basepath 42"     "$(basepath 42)"     "/pr-42"

echo "now_ms:"
NMS="$(now_ms)"
okm "now_ms is all digits" "$NMS" '^[0-9]+$'
okm "now_ms is a 13-digit ms epoch" "$NMS" '^[0-9]{13}$'

echo "sweep membership (the comma-wrapped open-set test):"
# Replicates the core predicate in preview-sweep.sh / preview-lib.sh sweep():
# a PR number N is "open" iff ",$OPEN," contains ",N,". Guards against the
# classic substring bug where "1" wrongly matches "10".
is_open() { local open="$1" n="$2"; [[ ",$open," == *",$n,"* ]] && echo yes || echo no; }
ok "51 open in [51]"            "$(is_open '51' 51)"      "yes"
ok "42 closed when open=[51]"   "$(is_open '51' 42)"      "no"
ok "1 not matched by 10"        "$(is_open '10,11' 1)"    "no"
ok "10 open in [10,11]"         "$(is_open '10,11' 10)"   "yes"
ok "empty open set -> none open" "$(is_open '' 5)"        "no"
ok "multi: 7 open in [3,7,9]"   "$(is_open '3,7,9' 7)"    "yes"

echo "ci-wait-ready failure classification:"
# Mirror the classify logic in scripts/ci-wait-ready.sh (last_code -> reason).
classify() {
  case "$1" in
    000) echo "RoutingNotReady" ;;
    503) echo "HealthCheckFailed" ;;
    *)   echo "ReadinessTimeout" ;;
  esac
}
ok "000 -> RoutingNotReady"     "$(classify 000)" "RoutingNotReady"
ok "503 -> HealthCheckFailed"   "$(classify 503)" "HealthCheckFailed"
ok "200-but-stale -> Timeout"   "$(classify 200)" "ReadinessTimeout"
ok "404 -> ReadinessTimeout"    "$(classify 404)" "ReadinessTimeout"

# Assert the real script actually contains these reason tokens (guards drift).
echo "ci-wait-ready source contains the reason tokens:"
WR="$(cat "$ROOT/scripts/ci-wait-ready.sh")"
okm "has RoutingNotReady"   "$WR" 'RoutingNotReady'
okm "has HealthCheckFailed" "$WR" 'HealthCheckFailed'
okm "has ReadinessTimeout"  "$WR" 'ReadinessTimeout'

# Assert preview-sweep.sh is bash-3.2 safe (no mapfile — the regression we hit).
echo "preview-sweep.sh portability:"
# Strip comments before checking, so the "we don't use mapfile" note doesn't trip it.
SW="$(grep -vE '^\s*#' "$ROOT/scripts/preview-sweep.sh")"
if grep -q 'mapfile' <<<"$SW"; then echo "  ✗ preview-sweep.sh uses mapfile (breaks bash 3.2)"; fail=$((fail+1)); else echo "  ✓ no mapfile in code (bash 3.2 safe)"; pass=$((pass+1)); fi

# ── onboard-lib: routing-mode/readiness detection + helpers ──────
echo "onboard-lib:"
# shellcheck disable=SC1090
source "$ROOT/scripts/onboard-lib.sh"
ok "mode: basePath baked -> path"      "$(onboard_mode_for yes no)"  "path"
ok "mode: serves root -> host"         "$(onboard_mode_for no yes)"  "host"
ok "mode: unknown -> host (safe)"      "$(onboard_mode_for no no)"   "host"
ok "readiness: has sha -> sha gate"    "$(onboard_readiness_for yes)" "sha"
ok "readiness: no sha -> probe only"   "$(onboard_readiness_for no)"  "probe"
ok "ns_for 778"                        "$(onboard_ns_for 778)"        "pr-778"
ok "host_for"                          "$(onboard_host_for 778 preview.local)" "pr-778.preview.local"
ok "ecr repo from org/app"             "$(onboard_ecr_repo_for your-org/example-app)" "example-app/preview"
if onboard_valid_pr 778; then echo "  ✓ valid_pr accepts 778"; pass=$((pass+1)); else echo "  ✗ valid_pr 778"; fail=$((fail+1)); fi
if onboard_valid_pr "abc" 2>/dev/null; then echo "  ✗ valid_pr rejects abc"; fail=$((fail+1)); else echo "  ✓ valid_pr rejects abc"; pass=$((pass+1)); fi

echo "offboard safety guard (never touch non-preview namespaces):"
for ok_ns in pr-1 pr-777 pr-12345; do
  if onboard_is_preview_ns "$ok_ns"; then echo "  ✓ accepts $ok_ns"; pass=$((pass+1)); else echo "  ✗ should accept $ok_ns"; fail=$((fail+1)); fi
done
for bad_ns in example-app-prod kube-system external-secrets default pr- pr-abc preview; do
  if onboard_is_preview_ns "$bad_ns" 2>/dev/null; then echo "  ✗ MUST reject $bad_ns"; fail=$((fail+1)); else echo "  ✓ rejects $bad_ns"; pass=$((pass+1)); fi
done

# onboard-app.sh must be bash 3.2 safe (no associative arrays / mapfile).
echo "onboard-app.sh portability:"
OA="$(grep -vE '^\s*#' "$ROOT/scripts/onboard-app.sh")"
if grep -qE 'declare -A|mapfile' <<<"$OA"; then echo "  ✗ uses declare -A / mapfile (breaks bash 3.2)"; fail=$((fail+1)); else echo "  ✓ no declare -A / mapfile"; pass=$((pass+1)); fi

echo
echo "bash-lib: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
