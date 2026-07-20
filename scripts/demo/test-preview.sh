#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# test-preview.sh — run test cases against a live preview URL and post a clean
# pass/fail results comment on the PR. This is the second, TEST-ONLY step of the
# ABCA loop: the platform deploys a preview and (via the glue in
# abca-preview-controller.sh) triggers a test-task whose whole job is "given the
# preview URL, verify it and report on the PR".
#
# Two ways to run it, same behavior (mirrors the screenshot delivery split):
#   1. ABCA-native: a read-only `pr-review-v1` fork task (workflows/test-preview-v1)
#      runs inside ABCA and does exactly what this script does, via `gh pr comment`.
#   2. Local fallback (THIS script): for environments where ABCA's CDK can't be
#      redeployed to carry the fork workflow (no local ABCA checkout / no CDK
#      access). Runs the identical checks locally and posts the identical comment.
#   Either path proves the same loop; the local runner guarantees the results
#   comment where the ABCA-native task can't be deployed.
#
# What it tests against the live preview (from the app's own contract):
#   - /api/health returns 200 with { ready:true, sha:<pushed> }  (fresh-deploy gate)
#   - health echoes the expected prNumber + basePath (routing is correct)
#   - the rendered page under /pr-<n> loads (200) and, when EXPECT_TEXT is given,
#     contains that text (the actual change is live, not just a healthy pod)
#
# Usage: REPO=owner/app PR=<n> URL=https://<host>/pr-<n>[/ or signed] \
#        [SHA=<pushed>] [BASIC_AUTH=user:pass] [EXPECT_TEXT="Hello EKS #7"] \
#        [TEST_TIER=1..4] [CF_DOMAIN=<dist>] [CF_SIGNING_SECRET=<sm-id>] ./test-preview.sh
# Exit: 0 = tested + comment posted (pass OR fail verdict); 2 = inconclusive
#       (could not reach/verify the preview — an honest ⚠️ comment is still posted).
#
# TEST_TIER escalates rigor (each tier ADDS to the ones below it):
#   1 (default) — contract: reachability gate, SHA fresh-deploy, ready, routing, page, change
#   2 — depth: basePath echo, diagnostics sub-path, /api/health cache-control no-store
#   3 — security posture (CloudFront front-door only): UNSIGNED page must 403, health stays open
#   4 — adversarial: TAMPERED signature must 403 (gate not bypassable); cross-PR isolation
#       (this PR's URL never serves another PR's number)
set -uo pipefail
# shellcheck source=scripts/demo/gh-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/gh-lib.sh"
: "${REPO:?set REPO=owner/app}"; : "${PR:?set PR=<n>}"; : "${URL:?set URL=<preview-url>}"
BASIC_AUTH="${BASIC_AUTH:-}"
EXPECT_TEXT="${EXPECT_TEXT:-}"
TEST_TIER="${TEST_TIER:-1}"
# Prefer the SHA passed in (the controller passes the deployed SHA); else resolve it
# with the hardened, validated fetch (never a raw error-JSON).
SHA="${SHA:-$(pr_head_sha "$REPO" "$PR" 2>/dev/null || true)}"

# Query-stripped base: a signed CloudFront URL carries ?Expires&Signature; the
# app + its /api/health live on UNSIGNED behaviors, and the display link should be
# clean. Keep the signed URL intact for navigation, strip it for health + display.
BASE="${URL%%\?*}"; BASE="${BASE%/}"
HEALTH="${BASE}/api/health"
DISPLAY_URL="${DISPLAY_URL:-$BASE}"

# Inline basic-auth for navigation only (legacy path); never shown in the comment.
navurl="$URL"
if [ -n "$BASIC_AUTH" ]; then
  navurl="$(printf '%s' "$URL" | sed "s#://#://${BASIC_AUTH}@#")"
fi

log() { printf '\033[35m[test]\033[0m %s\n' "$*" >&2; }

# Post a PR comment and VERIFY it actually landed (a transient gh/API error can
# return an error-JSON instead of the created comment; the old code logged "posted"
# regardless). Retries, and only reports success when it gets a real comment URL.
# Echoes the comment URL on success; returns non-zero if it could never confirm one.
post_comment() {
  local body="$1" url _t
  for _t in 1 2 3 4; do
    url="$(gh api "repos/$REPO/issues/$PR/comments" -f body="$body" --jq '.html_url' 2>/dev/null)"
    case "$url" in https://github.com/*) printf '%s\n' "$url"; return 0;; esac
    sleep $(( _t * 2 ))
  done
  echo "[test] ERROR: could not post comment on PR #$PR after retries (transient gh/API error)" >&2
  return 1
}

# --- collect results -------------------------------------------------------
# Each check appends "PASS|name|detail" or "FAIL|name|detail" to results[].
results=(); verdict="pass"; inconclusive=""
add() { results+=("$1|$2|$3"); [ "$1" = FAIL ] && verdict="fail"; return 0; }

# san — neutralize a value read from /api/health before it is embedded in the PR
# comment. The preview app is PR-author-controlled, so its health JSON is untrusted:
# strip newlines/backticks/pipes/angle brackets (Markdown + comment control chars)
# and cap length, so a crafted health field can't inject content into the
# automation-authored comment. Comparisons still use the raw value; only the
# rendered detail text is sanitized.
san() { printf '%s' "$1" | tr -d '\n\r`|<>' | cut -c1-48; }

# REACHABILITY GATE (=> inconclusive, never a test FAIL). Two things must be
# reachable before we can honestly run checks:
#   (a) the ACTUAL page URL we were handed (the signed URL) returns 200 — this is
#       what catches an expired/403 signature. A signed URL's signature is bound to
#       /pr-N, so we verify THAT exact resource, not just the always-open health
#       behavior. Health-200-but-page-403 = expired signature = INCONCLUSIVE, not a
#       failed test (mirrors screenshot-preview.sh's refuse-to-post-a-403 discipline).
#   (b) /api/health (unsigned, always-open behavior) returns 200 so we can read the
#       runtime contract.
# Fetch the page body once (reused by the gate + content check) so an origin error
# page can be distinguished from the real app.
pfetch="$(curl -skL -m 20 -w $'\n%{http_code}' "$navurl" 2>/dev/null)"
pcode="$(printf '%s' "$pfetch" | tail -1)"
pbody="$(printf '%s' "$pfetch" | sed '$d')"
navhealth="$HEALTH"
[ -n "$BASIC_AUTH" ] && navhealth="$(printf '%s' "$HEALTH" | sed "s#://#://${BASIC_AUTH}@#")"
hbody="$(curl -sk -m 15 -w $'\n%{http_code}' "$navhealth" 2>/dev/null)"
hcode="$(printf '%s' "$hbody" | tail -1)"
hjson="$(printf '%s' "$hbody" | sed '$d')"
# An ALB/CloudFront ORIGIN-ERROR page ("503"-style) is returned with HTTP 200 but a
# canned error body — a transient pod-unavailable blip, NOT the app and NOT a real
# test failure. Detect it and treat as INCONCLUSIVE (retry-worthy), never a content FAIL.
origin_err=""
case "$pbody" in
  *"No server is currently available to service your request"*|*"503 Service Temporarily Unavailable"*|*"502 Bad Gateway"*|*"could not be satisfied"*)
    origin_err="1";;
esac
if [ "$pcode" != "200" ]; then
  inconclusive="preview page returned HTTP ${pcode:-000} (expired/invalid signed URL, or preview unreachable) — refusing to report a verdict on a page that won't load"
elif [ -n "$origin_err" ]; then
  inconclusive="preview served a transient origin-error page (HTTP 200 body from the ALB/CDN, pod momentarily unavailable) — not the app; re-run once the rollout settles"
elif [ "$hcode" != "200" ]; then
  inconclusive="preview /api/health returned HTTP ${hcode:-000} (unreachable / not ready)"
else
  # 2. SHA matches the pushed commit (fresh-deploy gate — never green on stale code).
  gotsha="$(printf '%s' "$hjson" | jq -r '.sha // empty' 2>/dev/null)"
  if [ -n "$SHA" ] && [ -n "$gotsha" ]; then
    if [ "$gotsha" = "$SHA" ] || [ "$gotsha" = "${SHA:0:7}" ] || [ "${gotsha:0:7}" = "${SHA:0:7}" ]; then
      add PASS "fresh-deploy SHA" "health sha \`$(san "$gotsha")\` == pushed \`${SHA:0:7}\`"
    else
      add FAIL "fresh-deploy SHA" "health sha \`$(san "$gotsha")\` != pushed \`${SHA:0:7}\` (stale deploy)"
    fi
  fi
  # 3. ready:true
  ready="$(printf '%s' "$hjson" | jq -r '.ready // empty' 2>/dev/null)"
  [ "$ready" = "true" ] && add PASS "readiness" "\`ready:true\`" || add FAIL "readiness" "\`ready:$(san "${ready:-missing}")\`"
  # 4. routing correct: health echoes the PR number it was built for
  gotpr="$(printf '%s' "$hjson" | jq -r '.prNumber // empty' 2>/dev/null)"
  if [ -n "$gotpr" ]; then
    [ "$gotpr" = "$PR" ] && add PASS "routing" "serves prNumber \`$(san "$gotpr")\`" \
                          || add FAIL "routing" "prNumber \`$(san "$gotpr")\` != \`$PR\`"
  fi
  # 5. the rendered page loads (already confirmed 200 by the reachability gate above).
  add PASS "page renders" "\`GET\` signed page → 200"
  # 6. content assertion: the actual change is live (only when EXPECT_TEXT given).
  # Reuse the page body fetched by the gate (already confirmed 200 + not an origin
  # error), so the content check sees exactly what the gate validated. When no
  # EXPECT_TEXT is available (e.g. the PR title carried no quoted change), DO NOT
  # silently pass — record an explicit "change unverified" note so a reachability-only
  # run is honestly distinguished from a real change-verified pass (T4-Q3).
  if [ -n "$EXPECT_TEXT" ]; then
    if printf '%s' "$pbody" | grep -qF "$EXPECT_TEXT"; then
      add PASS "change is live" "page contains \"$(san "$EXPECT_TEXT")\""
    else
      add FAIL "change is live" "page does NOT contain \"$(san "$EXPECT_TEXT")\""
    fi
  else
    add NOTE "change unverified" "no expected-change text supplied — verified reachability/SHA/routing only, NOT the visible change"
  fi

  # ===== TIER 2 — depth: routing echo + health-contract completeness =====
  if [ "$TEST_TIER" -ge 2 ]; then
    # basePath echoed correctly (path-mode routing wired end to end)
    gotbp="$(printf '%s' "$hjson" | jq -r '.basePath // empty' 2>/dev/null)"
    if [ -n "$gotbp" ]; then
      [ "$gotbp" = "/pr-$PR" ] && add PASS "basePath echo" "serves basePath \`$(san "$gotbp")\`" \
                               || add FAIL "basePath echo" "basePath \`$(san "$gotbp")\` != \`/pr-$PR\`"
    fi
    # routing mode is 'path' (the front-door/demo uses path mode, not host mode)
    gotrm="$(printf '%s' "$hjson" | jq -r '.routingMode // empty' 2>/dev/null)"
    [ "$gotrm" = "path" ] && add PASS "routing mode" "\`routingMode=path\`" \
                          || add FAIL "routing mode" "routingMode \`$(san "${gotrm:-<none>}")\` (expected path)"
    # health contract completeness: it's the REAL app (service + uptime present, JSON well-formed),
    # not a stub, an error page, or a CDN interstitial that happens to 200.
    svc="$(printf '%s' "$hjson" | jq -r '.service // empty' 2>/dev/null)"
    up="$(printf '%s' "$hjson" | jq -r '.uptimeSec // empty' 2>/dev/null)"
    if [ -n "$svc" ] && printf '%s' "$up" | grep -qE '^[0-9]+$'; then
      add PASS "health contract" "\`service=$(san "$svc")\`, uptime \`${up}s\` (full contract)"
    else
      add FAIL "health contract" "health missing service/uptime (service=\`$(san "${svc:-}")\`, uptime=\`$(san "${up:-}")\`)"
    fi
  fi

  # ===== TIER 3 — security posture: the front-door gate actually enforces =====
  # Only meaningful on the CloudFront signed-URL front-door (CF_DOMAIN set). On the
  # legacy public-ALB path there is no signature to strip, so skip cleanly.
  if [ "$TEST_TIER" -ge 3 ] && [ -n "${CF_DOMAIN:-}" ]; then
    # UNSIGNED page request must be denied (403) — proves access requires the signature,
    # i.e. the private-ALB-behind-CloudFront gate is doing its job.
    ucode="$(curl -sk -m 15 -o /dev/null -w '%{http_code}' "$BASE" 2>/dev/null)"
    if [ "$ucode" = "403" ]; then
      add PASS "unsigned denied" "unsigned \`$BASE\` → 403 (gate enforced)"
    else
      add FAIL "unsigned denied" "unsigned page → HTTP ${ucode:-000} (expected 403 — gate NOT enforcing)"
    fi
  fi

  # ===== TIER 4 — adversarial: tampering + isolation =====
  if [ "$TEST_TIER" -ge 4 ] && [ -n "${CF_DOMAIN:-}" ]; then
    # TAMPERED signature must 403: flip the tail of the Signature and confirm it's rejected.
    if printf '%s' "$URL" | grep -q 'Signature='; then
      tampered="$(printf '%s' "$URL" | sed -E 's/(Signature=[A-Za-z0-9_~-]{6})[A-Za-z0-9_~-]{6}/\1AAAAAA/')"
      tcode="$(curl -sk -m 15 -o /dev/null -w '%{http_code}' "$tampered" 2>/dev/null)"
      if [ "$tcode" = "403" ]; then
        add PASS "tamper-proof sig" "tampered signature → 403 (not bypassable)"
      else
        add FAIL "tamper-proof sig" "tampered signature → HTTP ${tcode:-000} (expected 403!)"
      fi
    fi
    # cross-PR isolation: this PR's health must report ITS OWN prNumber, never another's
    # (a routing/isolation bug could serve pr-<m>'s pod under pr-<n>'s URL).
    isopr="$(printf '%s' "$hjson" | jq -r '.prNumber // empty' 2>/dev/null)"
    if [ -n "$isopr" ]; then
      [ "$isopr" = "$PR" ] && add PASS "PR isolation" "URL serves only PR \`$PR\`'s pod" \
                            || add FAIL "PR isolation" "URL for PR $PR served prNumber \`$(san "$isopr")\` (cross-PR leak!)"
    fi
  fi
fi

# --- build the comment -----------------------------------------------------
tested_sha="${SHA:0:7}"
if [ -n "$inconclusive" ]; then
  log "INCONCLUSIVE: $inconclusive"
  body="⚠️ **Preview test — inconclusive**

Could not verify the preview, so no pass/fail was recorded: **${inconclusive}**.

Tested against [\`${DISPLAY_URL}\`](${URL}) at SHA \`${tested_sha}\`. This is not a test failure — the preview could not be reached (a re-run once it's healthy will produce a verdict). No stale or unreachable page is ever reported as passing."
  post_comment "$body" || exit 3
  echo "[test] posted INCONCLUSIVE comment on PR #$PR" >&2
  exit 2
fi

# Render the per-check table.
rows=""; npass=0; nfail=0
nnote=0
for r in "${results[@]}"; do
  st="${r%%|*}"; rest="${r#*|}"; name="${rest%%|*}"; detail="${rest#*|}"
  case "$st" in
    PASS) icon="✅"; npass=$((npass+1));;
    NOTE) icon="⚠️"; nnote=$((nnote+1));;
    *)    icon="❌"; nfail=$((nfail+1));;
  esac
  rows+="| ${icon} | ${name} | ${detail} |
"
done

tier_label=""; [ "$TEST_TIER" -ge 2 ] && tier_label=" (tier ${TEST_TIER})"
# A NOTE (e.g. change-unverified) doesn't fail the verdict, but it must be visible in
# the header so an "all passed" can't be read as full change-verification.
note_label=""; [ "$nnote" -gt 0 ] && note_label=" · ${nnote} note$([ "$nnote" -gt 1 ] && echo s)"
if [ "$verdict" = pass ]; then
  header="✅ **Preview tested — all ${npass} checks passed${tier_label}${note_label}**"
else
  header="❌ **Preview tested — ${nfail} of $((npass+nfail)) checks failed${tier_label}${note_label}**"
fi

# Screenshot as evidence (embed if the poster produced a hosted image for this SHA).
shot_line=""
if [ -n "${SCREENSHOT_CF:-}" ]; then
  key="screenshots/$(printf '%s' "$REPO" | tr '/' '_')/${SHA}.png"
  shot_url="https://${SCREENSHOT_CF}/${key}"
  if [ "$(curl -s -m 10 -o /dev/null -w '%{http_code}' "$shot_url" 2>/dev/null)" = "200" ]; then
    shot_line="

[![preview](${shot_url})](${URL})
_Live preview at the tested SHA._"
  fi
fi

body="${header}

Tested the live preview at [\`${DISPLAY_URL}\`](${URL}) · SHA \`${tested_sha}\`

| | check | detail |
|---|---|---|
${rows}${shot_line}

<sub>Posted by the preview test-task — verifies the deployed change against the real EKS preview, opens no PR, pushes nothing.</sub>"

post_comment "$body" || exit 3
VUP="$(printf '%s' "$verdict" | tr '[:lower:]' '[:upper:]')"
log "posted $VUP results comment on PR #$PR (${npass} pass / ${nfail} fail)"
exit 0
