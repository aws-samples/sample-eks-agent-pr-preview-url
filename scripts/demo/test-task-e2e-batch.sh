#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# test-task-e2e-batch.sh — end-to-end batch for the preview TEST-TASK loop:
#   deploy a PR's preview → controller glue triggers the test-task → test-task
#   verifies the LIVE preview (SHA/ready/routing/page/change) → posts a pass/fail
#   comment on the PR. Runs N consecutive cycles and asserts the verdict each time.
#
# This exercises the second-test-task feature's FULL path against the real EKS
# cluster + CloudFront front-door. It deploys each cycle fresh (so the SHA-gate,
# signing, and glue all run for real), then verifies that a correct test-result
# comment landed for the deployed SHA.
#
# Unlike abca-e2e-batch.sh (which submits a fresh ABCA agent task per cycle, ~40
# min each), this reuses existing open PRs to exercise the deploy→test loop
# deterministically and quickly, so 10 consecutive runs are feasible.
#
# Env: N (default 10), REPO, CF_DOMAIN (+ signing), SCREENSHOT_CF.
#      PRS="46 45 43 ..." (default: all open PRs). Cycles round-robin over PRS.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[ -f "$ROOT/project.local.env" ] && source "$ROOT/project.local.env"
[ -f "$ROOT/project.env" ] && source "$ROOT/project.env"
# shellcheck source=scripts/demo/gh-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/gh-lib.sh"
N="${N:-10}"
: "${REPO:?}"; : "${CF_DOMAIN:?this harness targets the CloudFront front-door — set CF_DOMAIN}"
export CF_DOMAIN CF_SIGNING_SECRET SCREENSHOT_CF REPO

# The pool of PRs to cycle over (default: every open PR on the repo).
if [ -z "${PRS:-}" ]; then
  PRS="$(gh api "repos/$REPO/pulls?state=open&per_page=100" --jq '.[].number' 2>/dev/null | tr '\n' ' ')"
fi
read -ra POOL <<< "$PRS"
[ "${#POOL[@]}" -gt 0 ] || { echo "[e2e] no open PRs to cycle over" >&2; exit 1; }
echo "[e2e] PR pool: ${POOL[*]}  ·  N=$N" >&2

# Escalating difficulty: the tier ramps as cycles progress, so later cycles run
# strictly harder checks (depth → security posture → adversarial). With the default
# N=20 that's 5 cycles per tier; TIERS can be overridden. A single-tier run
# (e.g. TEST_TIER=4 for all) is also supported by pinning TEST_TIER in the env.
pass=0; fail=0; consec=0; maxconsec=0; results=""
tier_for_cycle() {
  # map cycle i (1..N) → tier 1..4, evenly across N (min tier 1, max tier 4)
  if [ -n "${TEST_TIER:-}" ]; then printf '%s' "$TEST_TIER"; return; fi
  local i="$1"; local n=$(( N > 0 ? N : 1 )); local t=$(( ( (i-1) * 4 ) / n + 1 ))
  [ "$t" -gt 4 ] && t=4; printf '%s' "$t"
}
for i in $(seq 1 "$N"); do
  pr="${POOL[$(( (i-1) % ${#POOL[@]} ))]}"
  tier="$(tier_for_cycle "$i")"
  echo "==================== CYCLE $i / $N  (PR #$pr · tier $tier) ====================" >&2
  # pr_head_sha (gh-lib.sh) validates hex + retries so a transient gh error-JSON
  # can't become a bogus SHA that never matches the posted comment.
  sha="$(pr_head_sha "$REPO" "$pr")" || { echo "[cycle $i] FAIL: could not resolve PR #$pr head SHA (gh/API blip)" >&2; fail=$((fail+1)); consec=0; results+="cycle $i (PR#$pr, tier $tier): FAIL (sha resolve)\n"; continue; }
  # Clear any prior test comment for THIS sha so the glue's idempotency doesn't
  # skip (we want a real test each cycle) and so we assert on a fresh comment.
  for id in $(gh api "repos/$REPO/issues/$pr/comments" --jq ".[] | select(.body | test(\"Preview test\")) | select(.body | test(\"SHA .${sha}\")) | .id" 2>/dev/null); do
    gh api -X DELETE "repos/$REPO/issues/comments/$id" >/dev/null 2>&1
  done
  # Full path: deploy the preview + trigger the test-task at this cycle's tier
  # (screenshot off for speed).
  if TEST_TASK=1 TEST_TIER="$tier" POST_SCREENSHOT=0 bash "$ROOT/scripts/demo/abca-preview-controller.sh" pr "$pr" >"/tmp/e2e_ctl_$i.log" 2>&1; then
    # Assert: a test-result comment for THIS sha exists and its verdict is coherent.
    # Select the LAST matching comment whole via jq (piping to `tail -1` would keep
    # only the final LINE of a multi-line body, dropping the verdict header). Grab
    # just the header line for a clean, glob-proof verdict match.
    # POLL for the comment: the GitHub comments API is eventually consistent, so a
    # just-posted comment may not surface on the first read (observed under the faster
    # tier-4 cadence). Retry a few times before concluding it's missing.
    body=""; header=""
    for _try in 1 2 3 4 5 6; do
      body="$(gh api "repos/$REPO/issues/$pr/comments" \
        --jq "[.[] | select(.body | test(\"Preview test\")) | select(.body | test(\"SHA .${sha}\"))] | last | .body // empty" 2>/dev/null)"
      header="$(printf '%s\n' "$body" | grep -m1 -E 'Preview test')"
      [ -n "$header" ] && break
      sleep 3
    done
    if [ -z "$body" ]; then
      echo "[cycle $i] FAIL: no test-result comment for SHA $sha on PR #$pr (after polling)" >&2
      fail=$((fail+1)); consec=0; results+="cycle $i (PR#$pr, tier $tier): FAIL (no comment)\n"
      [ "$consec" -gt "$maxconsec" ] && maxconsec="$consec"; continue
    fi
    verdict="$(printf '%s' "$header" | grep -oE '(all [0-9]+ checks passed|[0-9]+ of [0-9]+ checks failed|inconclusive)' | head -1)"
    case "$header" in
      *"all "*"checks passed"*)
        echo "[cycle $i] PASS — PR #$pr tier $tier tested green ($verdict)" >&2
        pass=$((pass+1)); consec=$((consec+1)); results+="cycle $i (PR#$pr, tier $tier): PASS ($verdict)\n";;
      *"checks failed"*)
        # A real test failure is a VALID e2e outcome only if the preview genuinely
        # mismatches; for a healthy fresh deploy it indicates a defect => batch FAIL.
        echo "[cycle $i] FAIL: test-task reported failures — $verdict" >&2
        fail=$((fail+1)); consec=0; results+="cycle $i (PR#$pr, tier $tier): FAIL ($verdict)\n";;
      *inconclusive*)
        echo "[cycle $i] FAIL: inconclusive (preview unreachable at test time) — $verdict" >&2
        fail=$((fail+1)); consec=0; results+="cycle $i (PR#$pr, tier $tier): FAIL (inconclusive)\n";;
      *)
        echo "[cycle $i] FAIL: unrecognized verdict on PR #$pr" >&2
        fail=$((fail+1)); consec=0; results+="cycle $i (PR#$pr, tier $tier): FAIL (bad verdict)\n";;
    esac
  else
    echo "[cycle $i] FAIL: controller failed for PR #$pr (see /tmp/e2e_ctl_$i.log)" >&2
    fail=$((fail+1)); consec=0; results+="cycle $i (PR#$pr, tier $tier): FAIL (controller)\n"
  fi
  [ "$consec" -gt "$maxconsec" ] && maxconsec="$consec"
done
echo "" >&2
echo "==================== TEST-TASK E2E SUMMARY ====================" >&2
printf '%b' "$results" >&2
echo "PASS=$pass FAIL=$fail / $N   ·   max consecutive clean=$maxconsec" >&2
# Success = zero failures AND at least MIN_CONSEC consecutive clean cycles (default 3).
[ "$fail" -eq 0 ] && [ "$maxconsec" -ge "${MIN_CONSEC:-3}" ]
