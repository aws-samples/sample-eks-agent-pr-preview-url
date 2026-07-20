#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# screenshot-preview.sh — capture the live preview URL and post it as a PR comment.
#
# This mirrors what ABCA's Deploy-Preview-Screenshots pipeline does (capture the
# deployment_status environment_url, post the image on the PR). We provide it as
# a controllable fallback for environments where ABCA's AgentCore-browser CDP
# client can't connect (its WSS handshake hangs in some accounts); the
# integration + deployment_status contract are identical either way.
#
# Uses local headless Chrome (accepts the basic-auth creds inline + self-signed
# cert), uploads the PNG to the screenshot S3 bucket, and posts a PR comment
# with the CloudFront image — same comment shape ABCA uses.
#
# Usage: REPO=owner/app PR=<n> URL=https://<alb>/pr-<n>/ BASIC_AUTH=user:pass \
#        SCREENSHOT_BUCKET=<s3> SCREENSHOT_CF=<cloudfront-domain> ./screenshot-preview.sh
set -uo pipefail
# shellcheck source=scripts/demo/gh-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/gh-lib.sh"
: "${REPO:?}"; : "${PR:?}"; : "${URL:?}"
BASIC_AUTH="${BASIC_AUTH:-}"
BUCKET="${SCREENSHOT_BUCKET:-}"; CF="${SCREENSHOT_CF:-}"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
# Validated, retrying head-SHA fetch (a transient gh error-JSON would otherwise
# become a bogus SHA baked into the comment + screenshot filename).
SHA="$(pr_head_sha "$REPO" "$PR" 2>/dev/null || true)"

# Build a navigable URL with inline creds (never shown in the comment).
navurl="$URL"
if [ -n "$BASIC_AUTH" ]; then
  navurl="$(printf '%s' "$URL" | sed "s#://#://${BASIC_AUTH}@#")"
fi

# Display text for the link. A CloudFront signed URL carries an Expires/Signature
# query string; keep the clickable href intact (so it works until it expires) but
# show a clean, query-stripped label so the comment isn't a wall of signature.
DISPLAY_URL="${DISPLAY_URL:-${URL%%\?*}}"

# PRE-CAPTURE VERIFY: never screenshot-and-post a page that isn't actually the
# live preview. Confirm the navigable URL returns 200 AND (when we can read it)
# the pushed SHA, so a 403 (expired/failed signature), an auth wall, or a stale
# page can't masquerade as a verified screenshot. Set SHOT_VERIFY=0 to skip.
if [ "${SHOT_VERIFY:-1}" = "1" ]; then
  code="$(curl -skL -m 15 -o /dev/null -w '%{http_code}' "$navurl" 2>/dev/null)"
  if [ "$code" != "200" ]; then
    echo "[shot] REFUSING to post: preview URL returned HTTP $code (expected 200) — signed URL invalid / not served" >&2
    exit 2
  fi
  # SHA-match: the app embeds the build SHA; the health endpoint returns it as JSON.
  # Health is served by an UNSIGNED CloudFront behavior, so query the query-stripped
  # base (a signed URL's signature is bound to /pr-N, not /pr-N/api/health).
  health="${DISPLAY_URL%/}/api/health"
  got="$(curl -skL -m 12 "$health" 2>/dev/null | jq -r '.sha // empty' 2>/dev/null)"
  if [ -n "$got" ] && [ -n "$SHA" ] && [ "$got" != "${SHA:0:7}" ] && [ "$got" != "$SHA" ]; then
    echo "[shot] REFUSING to post: preview serves SHA '$got' but PR head is '${SHA:0:7}' (stale)" >&2
    exit 2
  fi
  echo "[shot] pre-capture verify OK — 200 + SHA ${got:-<unchecked>}" >&2
fi

tmp="$(mktemp -d)"; png="$tmp/pr-${PR}.png"
echo "[shot] capturing $URL" >&2
"$CHROME" --headless --disable-gpu --ignore-certificate-errors --hide-scrollbars \
  --window-size=1280,800 --screenshot="$png" "$navurl" >/dev/null 2>&1
[ -s "$png" ] || { echo "[shot] capture failed" >&2; rm -rf "$tmp"; exit 1; }

# Upload to the ABCA screenshot bucket (private; served via CloudFront), or a
# local fallback path. Key mirrors ABCA's scheme: screenshots/<owner>_<repo>/<sha>.png
img_md=""
if [ -n "$BUCKET" ] && [ -n "$CF" ]; then
  key="screenshots/$(printf '%s' "$REPO" | tr '/' '_')/${SHA}.png"
  aws s3 cp "$png" "s3://${BUCKET}/${key}" --content-type image/png >/dev/null 2>&1 \
    && img_md="https://${CF}/${key}"
fi

if [ -n "$img_md" ]; then
  body="🖼️ **Preview screenshot**

[![preview](${img_md})](${URL})

_Captured from the live EKS preview after the deploy finished — verifying the change at [${DISPLAY_URL}](${URL})._"
else
  # No bucket: attach nothing hosted, but still record the verified capture.
  body="🖼️ **Preview verified** at [${DISPLAY_URL}](${URL}) (SHA \`${SHA:0:7}\`) — screenshot captured locally ($(du -h "$png" | cut -f1))."
fi
gh api "repos/$REPO/issues/$PR/comments" -f body="$body" --jq '.html_url' 2>&1 | head -1
echo "[shot] posted screenshot comment on PR #$PR" >&2
rm -rf "$tmp"
