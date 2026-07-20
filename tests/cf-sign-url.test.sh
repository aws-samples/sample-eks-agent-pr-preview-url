#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# cf-sign-url.test.sh — tests for the CloudFront signed-URL signer, exercising
# the REAL scripts/demo/cf-sign-url.sh via a stubbed `aws secretsmanager` (so no
# AWS calls) and a throwaway RSA key. Verifies the signature actually validates
# against the public key, the CloudFront URL-safe base64 alphabet is applied, and
# the expiry is honored (using the SIGN_EXPIRES test hook the script exposes).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIGNER="$ROOT/scripts/demo/cf-sign-url.sh"
pass=0; fail=0
ok()  { echo "  ✓ $1"; pass=$((pass+1)); }
bad() { echo "  ✗ $1"; fail=$((fail+1)); }

command -v openssl >/dev/null 2>&1 || { echo "openssl required for this test" >&2; exit 0; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
# throwaway signing key + its public key
openssl genrsa -out "$WORK/priv.pem" 2048 2>/dev/null
openssl rsa -pubout -in "$WORK/priv.pem" -out "$WORK/pub.pem" 2>/dev/null

# stub `aws` so `aws secretsmanager get-secret-value ... --query SecretString`
# returns the {privateKey, keyPairId} JSON the signer expects — no real AWS.
cat > "$WORK/aws" <<STUB
#!/usr/bin/env bash
# only the get-secret-value path is used by the signer
if printf '%s ' "\$@" | grep -q 'get-secret-value'; then
  jq -nc --arg pk "\$(cat "$WORK/priv.pem")" --arg id "TESTKEYPAIRID" '{privateKey:\$pk, keyPairId:\$id}'
  exit 0
fi
exit 0
STUB
chmod +x "$WORK/aws"
export PATH="$WORK:$PATH"

URL="https://d123.cloudfront.net/pr-42"
EXP=2000000000   # fixed epoch via the SIGN_EXPIRES test hook

echo "cf-sign-url.sh signer (real script, stubbed Secrets Manager):"

SIGNED="$(SIGN_EXPIRES="$EXP" bash "$SIGNER" "$URL" 2>/dev/null)"

# 1. shape: has the three canned-policy query params + correct key id + the base url
case "$SIGNED" in
  "$URL?Expires=$EXP&Signature="*"&Key-Pair-Id=TESTKEYPAIRID") ok "emits Expires+Signature+Key-Pair-Id in canned-policy shape" ;;
  *) bad "unexpected signed URL shape: $SIGNED" ;;
esac

# 2. expiry is the one we pinned
case "$SIGNED" in *"Expires=$EXP"*) ok "honors SIGN_EXPIRES (expiry math/hook)" ;; *) bad "expiry not honored" ;; esac

# 3. CloudFront URL-safe alphabet: signature must not contain +, =, or / (they map to -, _, ~)
SIG="$(printf '%s' "$SIGNED" | sed -n 's/.*Signature=\([^&]*\).*/\1/p')"
if printf '%s' "$SIG" | grep -q '[+/=]'; then bad "signature contains raw base64 chars (+/=), alphabet not translated"; else ok "signature uses CloudFront URL-safe alphabet (no +/=)"; fi

# 4. the signature actually VERIFIES against the public key over the canned policy
#    (reverse the alphabet, base64-decode, openssl verify RSA-SHA1 over the policy JSON)
POLICY="{\"Statement\":[{\"Resource\":\"${URL}\",\"Condition\":{\"DateLessThan\":{\"AWS:EpochTime\":${EXP}}}}]}"
printf '%s' "$SIG" | tr '\-_~' '+=/' | openssl base64 -d -A > "$WORK/sig.bin" 2>/dev/null
if printf '%s' "$POLICY" | openssl dgst -sha1 -verify "$WORK/pub.pem" -signature "$WORK/sig.bin" >/dev/null 2>&1; then
  ok "signature verifies against the public key (valid RSA-SHA1 over the canned policy)"
else
  bad "signature does NOT verify against the public key — signer would 403 at CloudFront"
fi

# 5. tampering the policy must fail verification (guards against a non-binding signature)
BADPOLICY="{\"Statement\":[{\"Resource\":\"https://evil.example/pr-42\",\"Condition\":{\"DateLessThan\":{\"AWS:EpochTime\":${EXP}}}}]}"
if printf '%s' "$BADPOLICY" | openssl dgst -sha1 -verify "$WORK/pub.pem" -signature "$WORK/sig.bin" >/dev/null 2>&1; then
  bad "a DIFFERENT resource verified with the same signature (signature not resource-bound!)"
else
  ok "signature is resource-bound (tampered policy fails verification)"
fi

echo ""
echo "cf-sign-url: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
