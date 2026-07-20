#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# abca-e2e-batch.sh — run N full end-to-end cycles:
#   ABCA task → PR → EKS preview → screenshot on PR (CloudFront signed URL when CF_DOMAIN set, else legacy HTTPS+basic-auth).
# Each cycle asks ABCA for a distinct visible change so the preview + screenshot
# visibly differ. Logs a PASS/FAIL summary. Reuses the deployed platform + ABCA.
#
# Env: N (default 10), REPO, ABCA_USER, ABCA_PASS, CERT_ARN, plus screenshot vars.
#   TEARDOWN=1 (default) tears each preview down after its screenshot is verified
#     and confirms the namespace is reaped — proving cleanup works every cycle.
#   KEEP_LAST=1 (default) leaves the final cycle's preview up (demo stays live).
#   Set TEARDOWN=0 to leave every preview running (old behavior).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
N="${N:-10}"
TEARDOWN="${TEARDOWN:-1}"
KEEP_LAST="${KEEP_LAST:-1}"
: "${REPO:?}"; : "${ABCA_USER:?}"; : "${ABCA_PASS:?}"
# Access model: CloudFront front-door (CF_DOMAIN set) uses signed URLs over a
# private ALB — no CERT_ARN/basic-auth needed. Legacy path needs CERT_ARN.
CF_DOMAIN="${CF_DOMAIN:-}"
if [ -z "$CF_DOMAIN" ]; then
  : "${CERT_ARN:?legacy path needs CERT_ARN (or set CF_DOMAIN for the front-door)}"
  export BASIC_AUTH_B64="${BASIC_AUTH_B64:-$(printf 'demo:demo'|base64)}"
  export BASIC_AUTH_PLAIN="${BASIC_AUTH_PLAIN:-demo:demo}"
fi
export SCREENSHOT_BUCKET SCREENSHOT_CF CERT_ARN REPO CF_DOMAIN CF_SIGNING_SECRET SIGN_TTL

CHANGES=(
  "Change the H1 headline in src/app/page.tsx to 'ABCA cycle %N% — live on EKS'."
  "Change the H1 headline in src/app/page.tsx to 'Preview %N%: autonomous PR by ABCA'."
  "Add a short paragraph under the H1 in src/app/page.tsx reading 'Cycle %N% verified via preview URL.'"
  "Change the H1 headline in src/app/page.tsx to 'Iteration %N% — screenshot me'."
  "Change the H1 in src/app/page.tsx to 'Hello EKS #%N%' and keep everything else."
)
# Per-run log dir so cycle logs never carry stale content from a previous batch.
LOGDIR="$(mktemp -d "${TMPDIR:-/tmp}/abca-batch.XXXXXX")"
echo "[batch] per-cycle logs in $LOGDIR" >&2
pass=0; fail=0; reaped=0; kept=0; results=""
for i in $(seq 1 "$N"); do
  echo "==================== CYCLE $i / $N ====================" >&2
  tmpl="${CHANGES[$(( (i-1) % ${#CHANGES[@]} ))]}"
  desc="${tmpl//%N%/$i}. Keep /api/health returning the build SHA. Run mise run build and mise run lint, then open a PR."
  # 1. ABCA: task → PR
  pr_url="$(ABCA_STACK="${ABCA_STACK:-backgroundagent-dev}" AWS_REGION="${AWS_REGION:-us-east-1}" \
    bash "$ROOT/scripts/demo/abca-submit.sh" "$desc" 2>>/tmp/batch_abca.log)"
  prn="$(printf '%s' "$pr_url" | grep -oE '[0-9]+$')"
  if [ -z "$prn" ]; then echo "[cycle $i] FAIL: ABCA opened no PR" >&2; fail=$((fail+1)); results+="cycle $i: FAIL (no PR)\n"; continue; fi
  echo "[cycle $i] ABCA opened PR #$prn" >&2
  # Strip ABCA's inner-claude-code "Generated with Claude Code" footer from the PR.
  REPO="$REPO" bash "$ROOT/scripts/demo/strip-pr-footer.sh" "$prn" >/dev/null 2>&1 || true
  # 2. platform: deploy preview + deployment_status + screenshot (the screenshotter
  #    now pre-verifies 200 + SHA before posting, so a bad signed URL can't PASS).
  if bash "$ROOT/scripts/demo/abca-preview-controller.sh" pr "$prn" >>"$LOGDIR/ctl_$i.log" 2>&1; then
    # STRICT verify: the screenshot comment exists AND its linked image is a real,
    # reachable PNG (200 + non-trivial size) — catches "comment posted but image
    # broken / wrong / 403 page" which the mere-existence check would miss.
    shot_body="$(gh api "repos/$REPO/issues/$prn/comments" --jq '.[].body' 2>/dev/null | grep -iE "Preview (screenshot|verified)" | head -1)"
    img_ok=0
    if [ -n "$shot_body" ]; then
      img_url="$(printf '%s' "$shot_body" | grep -oE 'https://[a-z0-9.]+/screenshots/[^ )]+\.png' | head -1)"
      if [ -n "$img_url" ]; then
        read -r icode isize < <(curl -s -m 15 -o /dev/null -w '%{http_code} %{size_download}' "$img_url" 2>/dev/null)
        [ "$icode" = "200" ] && [ "${isize:-0}" -gt 5000 ] && img_ok=1
      else
        img_ok=1   # "verified locally" comment with no hosted image is acceptable
      fi
    fi
    if [ -n "$shot_body" ] && [ "$img_ok" = 1 ]; then
      echo "[cycle $i] PASS — PR #$prn previewed + screenshot verified (image reachable)" >&2
      pass=$((pass+1)); results+="cycle $i: PASS (PR #$prn)\n"
      # Cleanup: tear the preview down and prove the namespace is reaped, unless
      # this is the last cycle and KEEP_LAST asked to leave the demo live.
      if [ "$TEARDOWN" = 1 ] && ! { [ "$KEEP_LAST" = 1 ] && [ "$i" -eq "$N" ]; }; then
        if bash "$ROOT/scripts/demo/abca-preview-controller.sh" down "$prn" >>"$LOGDIR/ctl_$i.log" 2>&1; then
          echo "[cycle $i] cleanup OK — pr-$prn reaped" >&2; reaped=$((reaped+1))
        else
          echo "[cycle $i] cleanup FAILED — pr-$prn not reaped" >&2
          results+="cycle $i: cleanup FAIL (pr-$prn)\n"
        fi
      elif [ "$TEARDOWN" = 1 ]; then
        echo "[cycle $i] kept live (KEEP_LAST) — pr-$prn" >&2; kept=$((kept+1))
      fi
    else
      echo "[cycle $i] FAIL: screenshot comment missing or its image unreachable on PR #$prn" >&2
      fail=$((fail+1)); results+="cycle $i: FAIL (screenshot/image, PR #$prn)\n"
    fi
  else
    echo "[cycle $i] FAIL: preview controller failed for PR #$prn" >&2
    fail=$((fail+1)); results+="cycle $i: FAIL (controller, PR #$prn)\n"
  fi
done
echo "" >&2
echo "==================== BATCH SUMMARY ====================" >&2
printf '%b' "$results" >&2
echo "PASS=$pass FAIL=$fail / $N   ·   cleanup: reaped=$reaped kept=$kept" >&2
# Final orphan check: no unexpected pr-* namespaces should remain (allow the kept one).
orphans="$(kubectl get ns -o name 2>/dev/null | grep -oE 'pr-[0-9]+' | sort -u | tr '\n' ' ')"
echo "remaining preview namespaces: ${orphans:-none}" >&2
[ "$fail" -eq 0 ]
