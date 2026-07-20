#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# cf-sign-url.sh — mint a short-TTL CloudFront **signed URL** (canned policy),
# dependency-free (openssl + bash only; no AWS SDK).
#
# The private key + key-pair id are read from Secrets Manager so no key material
# lives on disk or in CI logs. The signature covers the exact resource URL and
# expires after $TTL seconds — CloudFront rejects it (403) before and after.
#
# Usage:  cf-sign-url.sh "https://d123.cloudfront.net/pr-42/"
# Env:    CF_SIGNING_SECRET (Secrets Manager id, default pr-preview/cloudfront-signing-key)
#         TTL (seconds, default 900), AWS_REGION (default us-east-1)
set -uo pipefail
URL="${1:?usage: cf-sign-url.sh <https-url>}"
SECRET_ID="${CF_SIGNING_SECRET:-pr-preview/cloudfront-signing-key}"
TTL="${TTL:-900}"
REGION="${AWS_REGION:-us-east-1}"
NOW_PLUS_TTL="${SIGN_EXPIRES:-}"   # test hook: pin the expiry epoch

# CloudFront's URL-safe base64 alphabet: + → -, = → _, / → ~
cf_b64() { openssl base64 -A | tr '+=/' '-_~'; }

# Fetch key material (privateKey PEM + keyPairId) from Secrets Manager.
secret_json="$(aws secretsmanager get-secret-value --region "$REGION" \
  --secret-id "$SECRET_ID" --query SecretString --output text 2>/dev/null)"
[ -n "$secret_json" ] || { echo "cf-sign: cannot read secret $SECRET_ID" >&2; exit 1; }
key_pair_id="$(printf '%s' "$secret_json" | jq -r '.keyPairId')"
key_file="$(mktemp)"; trap 'rm -f "$key_file"' EXIT
printf '%s' "$secret_json" | jq -r '.privateKey' > "$key_file"

# Canned policy: a fixed expiry, resource = the exact URL.
expires="${NOW_PLUS_TTL:-$(( $(date +%s) + TTL ))}"
policy="{\"Statement\":[{\"Resource\":\"${URL}\",\"Condition\":{\"DateLessThan\":{\"AWS:EpochTime\":${expires}}}}]}"

# Signature = RSA-SHA1 over the policy, CloudFront-base64'd.
sig="$(printf '%s' "$policy" | openssl sha1 -sign "$key_file" | cf_b64)"

# For a canned policy CloudFront wants Expires (not Policy) + Signature + Key-Pair-Id.
sep="?"; case "$URL" in *\?*) sep="&";; esac
printf '%s%sExpires=%s&Signature=%s&Key-Pair-Id=%s\n' "$URL" "$sep" "$expires" "$sig" "$key_pair_id"
