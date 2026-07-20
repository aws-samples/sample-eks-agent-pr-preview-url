#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# abca-preview-controller.sh — DEMO controller that runs the preview-URL
# platform's deploy logic against an app repo's open PRs, out-of-band from
# GitHub Actions (used when the reusable workflow isn't wired, e.g. eksctl
# clusters where the CI OIDC role has no k8s RBAC). It is the same chart +
# readiness gate + GitHub Deployment/deployment_status the platform's
# preview.yml uses — just triggered by a controller loop.
#
# For each open PR in $REPO it:
#   1. builds the app image at the PR head SHA and pushes to ECR
#   2. helm upgrade --install a path-mode preview into ns pr-<n>, with optional
#      HTTP basic auth (BASIC_AUTH_B64) — served over the shared ALB
#   3. waits until https://<alb>/... /api/health reports the pushed SHA
#   4. writes a GitHub Deployment + deployment_status(state=success,
#      environment_url=<clean https URL>, environment=$DEPLOY_ENVIRONMENT)
#      — exactly the contract ABCA's screenshot pipeline consumes.
#
# Usage:  REPO=owner/app ./scripts/demo/abca-preview-controller.sh once   # one pass
#         REPO=owner/app ./scripts/demo/abca-preview-controller.sh pr 7   # single PR
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=project.env
[ -f "$ROOT/project.env" ] && source "$ROOT/project.env"
# shellcheck source=scripts/demo/gh-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/gh-lib.sh"
: "${REPO:?set REPO=owner/app}"
AWS_REGION="${AWS_REGION:-us-east-1}"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
ECR="${ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPOSITORY:-pr-preview/app}"
CHART="$ROOT/charts/preview-env"
DEPLOY_ENVIRONMENT="${DEPLOY_ENVIRONMENT:-Preview}"   # must match ABCA SCREENSHOT_TARGET_ENVIRONMENT
BASE_DOMAIN="${BASE_DOMAIN:-preview.example.com}"     # host-header domain (not public DNS)
BASIC_AUTH_B64="${BASIC_AUTH_B64:-}"                  # base64("user:pass"); empty = public
READY_TIMEOUT="${READY_TIMEOUT:-300}"
# CloudFront front-door (opt-in): when CF_DOMAIN is set, the preview is served via
# a CloudFront distribution over a PRIVATE (internal) ALB. Access is a short-TTL
# SIGNED URL (no static password), so the ALB is not internet-reachable and the
# emitted environment_url is a *.cloudfront.net signed URL. When unset, the demo
# uses the legacy internet-facing ALB + basic-auth path.
CF_DOMAIN="${CF_DOMAIN:-}"
INGRESS_CLASS="${INGRESS_CLASS:-alb}"                 # 'alb-internal' under CloudFront
[ -n "$CF_DOMAIN" ] && INGRESS_CLASS="${INGRESS_CLASS_CF:-alb-internal}"

log()  { printf '\033[36m[ctl]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[31m[ctl:err]\033[0m %s\n' "$*" >&2; }

# The shared ALB hostname (discovered from any preview ingress after the first deploy).
alb_host() {
  kubectl get ingress -A -o jsonpath='{range .items[*]}{.status.loadBalancer.ingress[0].hostname}{"\n"}{end}' 2>/dev/null \
    | grep -m1 'elb.amazonaws.com' || true
}

deploy_pr() {
  local pr="$1" ns="pr-$1" sha
  # pr_head_sha (from gh-lib.sh) validates hex + retries, so a transient gh/API
  # error-JSON can't poison GIT_SHA. See gh-lib.sh for the why.
  sha="$(pr_head_sha "$REPO" "$pr")" || { err "PR $pr: could not resolve a valid head SHA (transient gh/API error?)"; return 1; }
  log "PR $pr head=$sha — build+push image"
  aws ecr get-login-password --region "$AWS_REGION" \
    | docker login --username AWS --password-stdin "${ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com" >/dev/null 2>&1

  # Clone the PR head and build the app image in PATH mode: basePath /pr-<n> is
  # baked at build time so the preview is served at https://<alb-hostname>/pr-<n>/.
  # Path mode uses the ALB's OWN DNS name (publicly resolvable), which ABCA's
  # AgentCore browser can reach — unlike a host-mode fake domain that has no DNS.
  local work; work="$(mktemp -d)"
  gh repo clone "$REPO" "$work/src" -- -q >/dev/null 2>&1
  git -C "$work/src" fetch -q origin "pull/$pr/head" && git -C "$work/src" checkout -q FETCH_HEAD
  local tag="${sha}-pr${pr}"
  # Build+push with a small retry — the build runs `npm ci`, so a transient npm
  # registry / network blip can fail an otherwise-fine build (observed in batch
  # runs). Retry up to BUILD_ATTEMPTS times with backoff before giving up.
  local attempt ok=""
  for attempt in $(seq 1 "${BUILD_ATTEMPTS:-3}"); do
    if docker build --platform linux/amd64 --build-arg GIT_SHA="$sha" \
        --build-arg PREVIEW_ROUTING_MODE=path --build-arg PREVIEW_BASE_PATH="/pr-${pr}" \
        -t "$ECR:$tag" "$work/src" >/dev/null 2>&1 \
       && docker push "$ECR:$tag" >/dev/null 2>&1; then
      ok=1; break
    fi
    err "build/push attempt $attempt failed$([ "$attempt" -lt "${BUILD_ATTEMPTS:-3}" ] && echo ' — retrying')"
    sleep $(( attempt * 5 ))
  done
  rm -rf "$work"
  [ -n "$ok" ] || { err "build/push failed after ${BUILD_ATTEMPTS:-3} attempts"; return 1; }

  # deploy the preview (path mode; HTTPS via ACM self-signed; optional basic auth)
  # Wait out any in-flight namespace termination from a prior teardown (a helm
  # install into a Terminating namespace fails).
  while kubectl get ns "$ns" -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Terminating; do sleep 3; done
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
  # Label the namespace so the scheduled preview-sweep can see + reap it. The
  # reaper selects on this label (fail-closed), so an unlabeled preview would be
  # invisible to it — the label is what makes this namespace sweep-eligible.
  kubectl label namespace "$ns" app.kubernetes.io/part-of=preview-platform --overwrite >/dev/null 2>&1
  local extra=()
  # Basic auth is the LEGACY access wall. Under the CloudFront front-door the
  # short-TTL SIGNED URL is the gate, so basic auth is redundant AND would 401 the
  # screenshotter (it presents no creds) — skip it when CF_DOMAIN is set.
  if [ -z "$CF_DOMAIN" ] && [ -n "$BASIC_AUTH_B64" ]; then
    kubectl create secret generic web-basic-auth -n "$ns" \
      --from-literal=credentials="$BASIC_AUTH_B64" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
    extra+=(--set basicAuth.enabled=true)
  fi
  # HTTPS on the shared PUBLIC ALB (legacy path): CERT_ARN is a self-signed cert
  # imported to ACM; the patched ABCA browser accepts it. Under the CloudFront
  # front-door this block is SKIPPED — the ALB is internal + http-only (CloudFront
  # terminates TLS), and a scheme:internet-facing / HTTPS-listener annotation here
  # would conflict with the alb-internal IngressClass and drop the rule from the
  # shared internal ALB.
  if [ -z "$CF_DOMAIN" ] && [ -n "${CERT_ARN:-}" ]; then
    extra+=(--set-string "routing.annotations.alb\.ingress\.kubernetes\.io/listen-ports=[{\"HTTPS\":443}]")
    extra+=(--set-string "routing.annotations.alb\.ingress\.kubernetes\.io/certificate-arn=${CERT_ARN}")
    extra+=(--set-string "routing.annotations.alb\.ingress\.kubernetes\.io/scheme=internet-facing")
  elif [ -n "$CF_DOMAIN" ]; then
    # CloudFront path: plain HTTP listener on the internal ALB.
    extra+=(--set-string "routing.annotations.alb\.ingress\.kubernetes\.io/listen-ports=[{\"HTTP\":80}]")
  fi
  log "PR $pr — helm upgrade --install (ns=$ns, env=$DEPLOY_ENVIRONMENT, path mode, auth=${BASIC_AUTH_B64:+on}, https=${CERT_ARN:+on})"
  helm upgrade --install web "$CHART" -n "$ns" \
    --set prNumber="$pr" --set commitSha="$sha" \
    --set image.repository="$ECR" --set image.tag="$tag" \
    --set routing.mode=path --set routing.ingressClassName="$INGRESS_CLASS" "${extra[@]+"${extra[@]}"}" >/dev/null 2>&1 \
    || { err "helm failed"; return 1; }

  # Readiness base: through CloudFront (unsigned /pr-*/api/health behavior) when
  # the front-door is on, else the resolvable public ALB path URL.
  local base ready_health
  if [ -n "$CF_DOMAIN" ]; then
    base="https://${CF_DOMAIN}/pr-${pr}"
    ready_health="${base}/api/health"           # unsigned CF behavior — no signature needed
    log "PR $pr — CloudFront front-door (private ALB); waiting for ${ready_health} = $sha"
  else
    local alb
    for _ in $(seq 1 40); do alb="$(alb_host)"; [ -n "$alb" ] && break; sleep 6; done
    [ -n "$alb" ] || { err "no ALB hostname"; return 1; }
    base="https://${alb}/pr-${pr}"
    ready_health="${base}/api/health"
    log "PR $pr — waiting for ${ready_health} = $sha"
  fi
  local ok=""
  local deadline=$(( $(date +%s) + READY_TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    got="$(curl -sk -m 8 "${ready_health}" 2>/dev/null | jq -r '.sha // empty' 2>/dev/null)"
    [ "$got" = "$sha" ] && { ok=1; break; }
    sleep 6
  done
  [ -n "$ok" ] || { err "PR $pr not ready in ${READY_TIMEOUT}s"; write_status "$pr" "$sha" failure ""; return 1; }

  # The environment_url ABCA screenshots + links in the PR comment.
  local url shot_auth=""
  if [ -n "$CF_DOMAIN" ]; then
    # Mint a short-TTL SIGNED CloudFront URL — no static password, self-expiring.
    # Sign the NO-trailing-slash resource: the app redirects /pr-N/ → /pr-N, and a
    # canned-policy signature is bound to one exact resource, so signing "/pr-N/"
    # would 403 after the redirect. Signing "/pr-N" matches the app's canonical URL.
    url="$(TTL="${SIGN_TTL:-1800}" bash "$(dirname "${BASH_SOURCE[0]}")/cf-sign-url.sh" "${base}" 2>/dev/null)"
    [ -n "$url" ] || { err "PR $pr — failed to sign CloudFront URL"; return 1; }
    log "PR $pr READY — signed CloudFront URL (expires in ${SIGN_TTL:-1800}s)"
  else
    # legacy: public ALB path URL, basic-auth supplied out of band to the screenshotter.
    url="${base}/"
    shot_auth="${BASIC_AUTH_PLAIN:-}"
    log "PR $pr READY — $url"
  fi
  log "PR $pr — writing deployment_status success/$DEPLOY_ENVIRONMENT"
  write_status "$pr" "$sha" success "$url"

  # Post the verified screenshot on the PR. Under CloudFront the signed URL needs
  # no creds; under the legacy path the basic-auth creds go out of band.
  if [ "${POST_SCREENSHOT:-1}" = "1" ]; then
    REPO="$REPO" PR="$pr" URL="$url" BASIC_AUTH="$shot_auth" \
      SCREENSHOT_BUCKET="${SCREENSHOT_BUCKET:-}" SCREENSHOT_CF="${SCREENSHOT_CF:-}" \
      bash "$(dirname "${BASH_SOURCE[0]}")/screenshot-preview.sh" >&2 || err "screenshot post failed (non-fatal)"
  fi

  # Trigger the second, TEST-ONLY task: given the preview URL just verified, run
  # test cases against it and post a pass/fail comment on the PR (opens no PR).
  # Opt-in via TEST_TASK=1 (default off — existing behavior unchanged when unset).
  if [ "${TEST_TASK:-0}" = "1" ]; then
    trigger_test_task "$pr" "$sha" "$url" "$shot_auth"
  fi
}

# Trigger the preview test-task for (pr, sha). Idempotent on (PR, SHA): if a test
# comment for this exact SHA already exists, skip — so a re-deploy of the same SHA
# never re-tests (the read-only test-task opens no PR / pushes nothing, so this is
# the only re-trigger vector). Prefers the ABCA-native webhook when configured;
# otherwise runs the local test-runner (same checks, same comment) — the same
# native/local split the screenshot pipeline uses.
trigger_test_task() {
  local pr="$1" sha="$2" url="$3" shot_auth="$4"
  # (PR, SHA) idempotency: a prior test-result comment naming this exact short SHA
  # means this SHA already got a real VERDICT => skip. Only a pass/fail verdict
  # ("Preview tested — … checks passed/failed") counts; an INCONCLUSIVE comment
  # ("Preview test — inconclusive") must NOT block a re-run, because it never
  # produced a verdict — re-running once the preview is healthy is the whole point.
  # SECURITY: only trust comments authored by OUR OWN automation identity — a PR
  # author can post a comment on their own PR, so matching any body would let them
  # pre-seed a fake "✅ Preview tested … SHA `x`" to suppress the real check
  # (verdict spoofing). Scope the select to the authenticated login.
  local short="${sha:0:7}" me
  me="$(gh api user --jq '.login' 2>/dev/null)"
  if [ -n "$me" ] && gh api "repos/$REPO/issues/$pr/comments" \
       --jq ".[] | select(.user.login == \"$me\") | select(.body | test(\"Preview tested\")) | select(.body | test(\"checks (passed|failed)\")) | .body" 2>/dev/null \
       | grep -qF "SHA \`${short}\`" 2>/dev/null; then
    log "PR $pr — our own verdict already exists for SHA ${short}; skipping (idempotent)"
    return 0
  fi
  # EXPECT_TEXT: the visible change to assert on the page. Derive from the PR title
  # (which reflects the change); the quoted phrase if present, else the whole title.
  # pr_title (gh-lib.sh) rejects a transient error-JSON, so its "message" can't be
  # mistaken for the expected text (which would cause a bogus content FAIL); on
  # failure expect stays empty and the content check skips rather than asserting garbage.
  local title expect=""
  title="$(pr_title "$REPO" "$pr")" || title=""
  if [ -n "$title" ]; then
    expect="$(printf '%s' "$title" | sed -n "s/.*'\([^']*\)'.*/\1/p")"
    [ -z "$expect" ] && expect="$(printf '%s' "$title" | sed -n 's/.*"\([^"]*\)".*/\1/p')"
    # The PR title is UNTRUSTED (an outside contributor controls it). expect is
    # embedded into the automation-authored "Preview tested" PR comment AND into the
    # ABCA test-task's task_description (an LLM prompt granted Bash/WebFetch). Two
    # defenses: (1) strip Markdown/link control chars so it can't inject fake
    # links/images into the bot comment, and (2) ENFORCE A STRICT ALLOWLIST so it
    # can't carry natural-language injected instructions to the agent — anything
    # outside a plain "change phrase" is dropped (content check then skips rather
    # than assert on, or forward, attacker text). The agent independently derives the
    # real change from the checked-out diff; expect is only a hint.
    expect="$(printf '%s' "$expect" | tr -d '`|[]()!<>')"
    case "$expect" in
      *[!A-Za-z0-9\ _.#/:-]*) expect="";;   # reject anything with unusual chars
    esac
    [ "${#expect}" -gt 60 ] && expect=""     # and anything suspiciously long
  fi

  # Native path: ABCA runs coding/test-preview-v1 via the HMAC webhook.
  if [ -n "${ABCA_WEBHOOK_URL:-}" ] && [ -n "${ABCA_WEBHOOK_ID:-}" ]; then
    log "PR $pr — triggering ABCA-native test-task (webhook)"
    REPO="$REPO" PR="$pr" URL="$url" EXPECT_TEXT="$expect" \
      bash "$(dirname "${BASH_SOURCE[0]}")/abca-submit-test-task.sh" >&2 \
      || err "PR $pr — ABCA test-task submit failed (non-fatal)"
  else
    # Local fallback: identical checks + comment, runnable without redeploying ABCA.
    # TEST_TIER (1..4) escalates rigor; CF_DOMAIN lets the runner add the front-door
    # security tiers (unsigned/tampered → 403). Both are pass-through (default tier 1).
    log "PR $pr — running local test-runner (ABCA webhook not configured, tier ${TEST_TIER:-1})"
    REPO="$REPO" PR="$pr" URL="$url" SHA="$sha" EXPECT_TEXT="$expect" \
      BASIC_AUTH="$shot_auth" SCREENSHOT_CF="${SCREENSHOT_CF:-}" \
      TEST_TIER="${TEST_TIER:-1}" CF_DOMAIN="${CF_DOMAIN:-}" \
      bash "$(dirname "${BASH_SOURCE[0]}")/test-preview.sh" >&2 \
      || err "PR $pr — local test-runner reported non-zero (inconclusive/fail; non-fatal)"
  fi
}

# Write GitHub Deployment + deployment_status. This is the exact event ABCA's
# screenshot pipeline consumes (state, environment_url, environment).
write_status() {
  local pr="$1" sha="$2" state="$3" url="$4" dep body
  # Create the Deployment (required_contexts:[] so it isn't blocked on checks).
  body="$(jq -nc --arg ref "$sha" --arg env "$DEPLOY_ENVIRONMENT" --arg d "preview pr-$pr" \
    '{ref:$ref,environment:$env,auto_merge:false,required_contexts:[],transient_environment:true,description:$d}')"
  dep="$(printf '%s' "$body" | gh api "repos/$REPO/deployments" -X POST --input - --jq '.id' 2>/dev/null)"
  [ -n "$dep" ] || { err "could not create deployment for pr-$pr"; return 1; }
  # Post the deployment_status ABCA consumes.
  if [ "$state" = success ]; then
    gh api "repos/$REPO/deployments/$dep/statuses" -X POST \
      -f state=success -f environment="$DEPLOY_ENVIRONMENT" \
      -f environment_url="$url" -f log_url="$url" -f description="preview ready" >/dev/null 2>&1
  else
    gh api "repos/$REPO/deployments/$dep/statuses" -X POST \
      -f state=failure -f environment="$DEPLOY_ENVIRONMENT" -f description="preview failed" >/dev/null 2>&1
  fi
}

# Tear down a PR's preview and prove it's gone. Mirrors what preview-teardown.yml
# does on PR close: helm uninstall, delete the namespace, mark the GitHub
# Deployment inactive, then wait until the namespace is actually reaped so
# cleanup is verifiable (returns non-zero if it doesn't disappear in time).
teardown_pr() {
  local pr="$1" ns="pr-$1"
  # Guard: only ever delete a numeric-PR namespace that carries the platform
  # label — so `down foo` can't target `pr-foo`, and we never delete a namespace
  # this platform didn't create (mirrors the offboard guard in onboard-app.sh).
  case "$pr" in ''|*[!0-9]*) err "teardown: PR must be a positive integer (got '$pr')"; return 2;; esac
  local label
  label="$(kubectl get ns "$ns" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}' 2>/dev/null)"
  if [ "$label" != "preview-platform" ]; then
    err "teardown: refusing $ns — not a platform preview namespace (label='${label}')"
    return 2
  fi
  log "PR $pr — teardown (helm uninstall + delete ns $ns)"
  helm uninstall web -n "$ns" >/dev/null 2>&1 || true
  kubectl delete namespace "$ns" --wait=false >/dev/null 2>&1 || true
  # Mark the most recent Deployment inactive so the PR's environment reads torn down.
  local dep tsha
  tsha="$(pr_head_sha "$REPO" "$pr" 2>/dev/null || true)"
  dep=""
  if [ -n "$tsha" ]; then
    dep="$(gh api "repos/$REPO/deployments?environment=${DEPLOY_ENVIRONMENT}&per_page=100" \
      --jq "[.[] | select(.ref | startswith(\"$tsha\"))][0].id" 2>/dev/null)"
  fi
  if [ -n "$dep" ] && [ "$dep" != "null" ]; then
    gh api "repos/$REPO/deployments/$dep/statuses" -X POST \
      -f state=inactive -f environment="$DEPLOY_ENVIRONMENT" -f description="preview torn down" >/dev/null 2>&1 || true
  fi
  # Verify reap: namespace must reach NotFound within the window.
  local deadline=$(( $(date +%s) + ${TEARDOWN_TIMEOUT:-180} ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    kubectl get ns "$ns" >/dev/null 2>&1 || { log "PR $pr — namespace $ns reaped ✓"; return 0; }
    sleep 4
  done
  err "PR $pr — namespace $ns still present after ${TEARDOWN_TIMEOUT:-180}s (cleanup FAILED)"
  return 1
}

case "${1:-once}" in
  pr)    deploy_pr "${2:?usage: pr <n>}";;
  down)  teardown_pr "${2:?usage: down <n>}";;
  once)  for n in $(gh api "repos/$REPO/pulls" --jq '.[].number' 2>/dev/null); do deploy_pr "$n"; done;;
  *)     err "usage: $0 once | pr <n> | down <n>"; exit 2;;
esac
