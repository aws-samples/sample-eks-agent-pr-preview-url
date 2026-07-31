#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# diagnose-oidc.sh — end-to-end diagnosis of the GitHub Actions -> AWS OIDC
# assume-role handshake for the PR-preview deploy role.
#
# It gathers everything needed to explain an "AssumeRoleWithWebIdentity" failure
# and reconciles the two sides that must agree:
#
#   GitHub side : the `sub` the app repo's workflow presents
#                 (repo:<owner>/<repo>:pull_request and :ref:refs/heads/main)
#   AWS side    : the LIVE trust policy on the deploy role, the account it lives
#                 in, and whether the GitHub OIDC provider exists there.
#
# It then GLOB-matches the presented subs against the trust's StringLike patterns
# and prints a PASS/FAIL verdict with the exact fix — no eyeballing JSON.
#
# Run it locally with AWS creds for the account the deploy role lives in
# (+ optionally `gh` authenticated to the app repo). Nothing is mutated.
#
# Usage:
#   scripts/diagnose-oidc.sh --repo <owner>/<name> \
#       [--role-arn arn:aws:iam::<acct>:role/<name>]  # the value of AWS_DEPLOY_ROLE_ARN
#       [--role-name <name>]                          # alt: name in the CURRENT account
#       [--region <r>]
#
#   # If --repo is omitted it is inferred from `gh repo view` (must be in the repo).
#   # If neither --role-arn nor --role-name is given, falls back to
#   # $DEPLOY_ROLE_NAME (project.env) in the current account, and WARNS that this
#   # may not be the role the secret actually points at.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Load project defaults (PROJECT_NAME/GITHUB_ORG/AWS_REGION/DEPLOY_ROLE_NAME...).
# shellcheck source=project.env
[ -f "$ROOT/project.env" ] && . "$ROOT/project.env"

log()  { printf '\033[36m[oidc]\033[0m %s\n' "$*" >&2; }
pass() { printf '\033[32m  PASS\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[31m  FAIL\033[0m %s\n' "$*" >&2; FAILURES=$((FAILURES+1)); }
warn() { printf '\033[33m  WARN\033[0m %s\n' "$*" >&2; WARNINGS=$((WARNINGS+1)); }
die()  { printf '\033[31m[oidc:err]\033[0m %s\n' "$*" >&2; exit 2; }

FAILURES=0
WARNINGS=0
REPO=""
ROLE_ARN=""
ROLE_NAME=""
REGION="${AWS_REGION:-us-east-1}"

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)      REPO="${2:?}"; shift 2 ;;
    --role-arn)  ROLE_ARN="${2:?}"; shift 2 ;;
    --role-name) ROLE_NAME="${2:?}"; shift 2 ;;
    --region)    REGION="${2:?}"; shift 2 ;;
    -h|--help)   grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           die "unknown arg: $1 (see --help)" ;;
  esac
done

command -v aws >/dev/null || die "aws CLI not found"
command -v jq  >/dev/null || die "jq not found"

# ---------------------------------------------------------------------------
# 1) GitHub side — which repo, and what sub will it present?
# ---------------------------------------------------------------------------
log "1/6  GitHub side — resolving the app repo + expected token sub"
if [ -z "$REPO" ]; then
  if command -v gh >/dev/null && gh repo view --json nameWithOwner >/dev/null 2>&1; then
    REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
    log "     inferred --repo from gh: $REPO"
  else
    die "no --repo given and could not infer it (run inside the app repo with gh, or pass --repo owner/name)"
  fi
fi
case "$REPO" in
  */*) : ;;
  *)   die "--repo must be <owner>/<name>, got: $REPO" ;;
esac
# The two subs the reusable preview workflows actually present (see preview.yml:
# pull_request events, and pushes to main). NEVER a bare '*'.
SUB_PR="repo:${REPO}:pull_request"
SUB_MAIN="repo:${REPO}:ref:refs/heads/main"
pass "app repo = $REPO"
log  "     will present sub: $SUB_PR"
log  "     will present sub: $SUB_MAIN"

# ---------------------------------------------------------------------------
# 2) AWS side — who am I, and which role are we diagnosing?
# ---------------------------------------------------------------------------
log "2/6  AWS side — current identity + target role"
CUR_ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" \
  || die "aws sts get-caller-identity failed — are you authenticated?"
pass "authenticated to account $CUR_ACCOUNT (region $REGION)"

if [ -z "$ROLE_ARN" ]; then
  ROLE_NAME="${ROLE_NAME:-${DEPLOY_ROLE_NAME:-${PROJECT_NAME:-pr-preview}-github-deploy}}"
  ROLE_ARN="arn:aws:iam::${CUR_ACCOUNT}:role/${ROLE_NAME}"
  warn "no --role-arn given; assuming $ROLE_ARN"
  warn "  -> this MUST equal the AWS_DEPLOY_ROLE_ARN secret in $REPO. If the"
  warn "     secret points elsewhere, the trust below is not the one being used."
fi
# Extract account + name from the ARN we're actually diagnosing.
ROLE_ACCOUNT="$(printf '%s' "$ROLE_ARN" | sed -nE 's|^arn:aws:iam::([0-9]+):role/.*|\1|p')"
ROLE_NAME="$(printf '%s' "$ROLE_ARN" | sed -nE 's|^arn:aws:iam::[0-9]+:role/(.+)$|\1|p')"
[ -n "$ROLE_ACCOUNT" ] && [ -n "$ROLE_NAME" ] || die "could not parse role ARN: $ROLE_ARN"
log "     diagnosing role: $ROLE_NAME  (account $ROLE_ACCOUNT)"

if [ "$ROLE_ACCOUNT" != "$CUR_ACCOUNT" ]; then
  fail "role lives in $ROLE_ACCOUNT but you're authenticated to $CUR_ACCOUNT."
  fail "  -> get-role below queries $CUR_ACCOUNT and will 404, OR you're looking"
  fail "     at the wrong account entirely. Auth to $ROLE_ACCOUNT and re-run."
fi

# ---------------------------------------------------------------------------
# 3) AWS side — does the GitHub OIDC provider exist in the role's account?
# ---------------------------------------------------------------------------
log "3/6  AWS side — GitHub OIDC provider (checkpoint 1: 'could not be validated')"
if aws iam list-open-id-connect-providers \
     --query "OpenIDConnectProviderList[?ends_with(Arn, ':oidc-provider/token.actions.githubusercontent.com')].Arn" \
     --output text 2>/dev/null | grep -q token.actions.githubusercontent.com; then
  pass "provider token.actions.githubusercontent.com exists in $CUR_ACCOUNT"
else
  fail "no token.actions.githubusercontent.com OIDC provider in $CUR_ACCOUNT."
  fail "  -> this CDK IMPORTS the provider, it does not create it. Create once:"
  fail "     aws iam create-open-id-connect-provider \\"
  fail "       --url https://token.actions.githubusercontent.com --client-id-list sts.amazonaws.com"
fi

# ---------------------------------------------------------------------------
# 4) AWS side — the LIVE trust policy on the role
# ---------------------------------------------------------------------------
log "4/6  AWS side — live trust policy (checkpoint 2: 'Not authorized')"
TRUST="$(aws iam get-role --role-name "$ROLE_NAME" \
          --query 'Role.AssumeRolePolicyDocument' --output json 2>/dev/null)" \
  || { fail "get-role failed for $ROLE_NAME in $CUR_ACCOUNT (missing role / wrong account)."; TRUST=""; }

if [ -n "$TRUST" ]; then
  AUD="$(printf '%s' "$TRUST" | jq -r '
    [.Statement[]?.Condition.StringEquals["token.actions.githubusercontent.com:aud"]] | flatten | .[0] // empty')"
  # Collect every sub pattern across all statements (StringLike and StringEquals).
  # Portable read loop (no mapfile — macOS ships bash 3.2, which lacks it).
  SUB_PATTERNS=()
  while IFS= read -r _p; do
    [ -n "$_p" ] && SUB_PATTERNS+=("$_p")
  done < <(printf '%s' "$TRUST" | jq -r '
    [.Statement[]?.Condition
      | (.StringLike, .StringEquals)
      | .["token.actions.githubusercontent.com:sub"]? ]
    | flatten | map(select(. != null)) | .[]')

  if [ "$AUD" = "sts.amazonaws.com" ]; then
    pass "aud condition = sts.amazonaws.com"
  else
    fail "aud condition is '${AUD:-<none>}', expected sts.amazonaws.com"
  fi

  if [ "${#SUB_PATTERNS[@]}" -eq 0 ]; then
    fail "trust has NO sub condition — it trusts no repo (or an unexpected shape)."
  else
    log "     trust sub patterns:"
    for p in "${SUB_PATTERNS[@]}"; do log "       - $p"; done
    # Flag the classic un-configured placeholder.
    for p in ${SUB_PATTERNS[@]+"${SUB_PATTERNS[@]}"}; do
      case "$p" in
        repo:your-org/*|repo:*/pr-preview:*)
          warn "sub pattern '$p' looks like the DEFAULT placeholder (your-org / pr-preview)."
          warn "  -> you deployed the CICD stack without -c githubOrg / -c githubRepo." ;;
      esac
    done
  fi

  # ---- 5) The reconciliation: does either presented sub match a trust pattern?
  log "5/6  Reconcile — does the presented sub match the trust guest list?"
  match_any() {  # $1 = concrete sub; returns 0 if any pattern globs it
    local sub="$1" pat
    for pat in ${SUB_PATTERNS[@]+"${SUB_PATTERNS[@]}"}; do
      # Intentional glob match: $pat contains '*' and must stay unquoted.
      # shellcheck disable=SC2053
      [[ "$sub" == $pat ]] && { printf '%s' "$pat"; return 0; }
    done
    return 1
  }
  for sub in "$SUB_PR" "$SUB_MAIN"; do
    if m="$(match_any "$sub")"; then
      pass "$sub  ⟵ matched by  $m"
    else
      fail "$sub  is NOT covered by any trust sub pattern."
    fi
  done
else
  log "5/6  Reconcile — skipped (no trust policy retrieved)"
fi

# ---------------------------------------------------------------------------
# 6) GitHub side — is the secret even set on the repo? (value is unreadable)
# ---------------------------------------------------------------------------
log "6/6  GitHub side — AWS_DEPLOY_ROLE_ARN secret presence"
if command -v gh >/dev/null && gh secret list --repo "$REPO" >/dev/null 2>&1; then
  if gh secret list --repo "$REPO" 2>/dev/null | grep -q '^AWS_DEPLOY_ROLE_ARN'; then
    pass "secret AWS_DEPLOY_ROLE_ARN is set on $REPO"
    warn "  (its VALUE can't be read via the API — confirm it equals $ROLE_ARN)"
  else
    fail "secret AWS_DEPLOY_ROLE_ARN is NOT set on $REPO — the workflow has no role to assume."
  fi
else
  warn "gh not available / not authed for $REPO — skipped secret check."
  warn "  confirm manually that AWS_DEPLOY_ROLE_ARN == $ROLE_ARN"
fi

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------
echo >&2
if [ "$FAILURES" -eq 0 ]; then
  log "VERDICT: no blocking failures. The trust on $ROLE_NAME authorizes $REPO."
  log "         If the workflow STILL fails, the running secret points at a"
  log "         different role than $ROLE_ARN — verify it, then re-run this."
  [ "$WARNINGS" -gt 0 ] && log "         ($WARNINGS warning(s) above — worth confirming.)"
  exit 0
fi
log "VERDICT: $FAILURES blocking failure(s) above. Most common durable fix —"
log "         redeploy the CICD stack so the CDK regenerates the trust (it never"
log "         writes a bare '*', so hand-edits get overwritten):"
log "           npx cdk deploy '*Cicd' \\"
log "             -c githubOrg=${REPO%%/*} -c githubRepo=${REPO##*/}"
log "         then point AWS_DEPLOY_ROLE_ARN at that role and re-run this script."
exit 1
