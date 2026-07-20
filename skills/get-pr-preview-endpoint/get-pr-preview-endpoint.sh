#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# get-pr-preview-endpoint.sh — print the pr-preview preview URL for a PR.
#
# SELF-CONTAINED & DROPPABLE: depends only on `gh` (authenticated) + standard
# coreutils. Copy this whole folder into any onboarded repo and run it; it does
# NOT need the pr-preview platform checkout.
#
# It reads the GitHub Deployment the preview workflow writes for environment
# `preview/pr-<N>` and prints that deployment's environment_url.
#
# Usage (auto-detects repo + PR when run inside a repo / PR checkout):
#   get-pr-preview-endpoint.sh [--repo <org/repo>] [--pr <n>] [--sha <commit>]
#                              [--wait <seconds>] [--json] [--quiet] [--doctor]
#
#   --sha     SHA-gate: only return the URL once the `preview` Check Run for THIS
#             commit is success AND the deployment is for it (fresh-deploy).
#   --wait N  poll up to N seconds for the URL (default 0 = one shot).
#   --json    print {url,state,pr,repo,sha} instead of the bare URL.
#   --doctor  DIAGNOSE the preview chain for this repo/PR and print the exact
#             missing link (gh auth, onboarding, deployment, freshness) instead
#             of a bare "no-deployment". Always exits 0 — it's a report, not a gate.
#
# EXIT REASONS (RESOLVED_STATE — also the --json "state"): success | not-onboarded
#   | no-deployment-yet | awaiting-sha:<conclusion> | deploy-pending:<state>
#   | deployment-no-url | gh-unauthenticated. These are actionable: "not-onboarded"
#   means add the caller workflow; "no-deployment-yet" means it's onboarded but the
#   preview hasn't built; "awaiting-sha" means THIS commit's preview isn't green yet.
set -uo pipefail

# ── args (bash 3.2 safe; no associative arrays) ──────────────────────────────
ARGV=("$@")
arg() { local i nxt; for ((i=0;i<${#ARGV[@]};i++)); do
  if [ "${ARGV[$i]}" = "--$1" ]; then nxt="${ARGV[$((i+1))]:-}"; case "$nxt" in --*) nxt="";; esac; echo "$nxt"; return; fi
done; echo "${2:-}"; }
argflag() { local a; for a in ${ARGV[@]+"${ARGV[@]}"}; do [ "$a" = "$1" ] && return 0; done; return 1; }

REPO="$(arg repo)"; PR="$(arg pr)"; SHA="$(arg sha)"
WAIT="$(arg wait 0)"; JSON=no; QUIET=no; DOCTOR=no
argflag --json && JSON=yes
argflag --quiet && QUIET=yes
argflag --doctor && DOCTOR=yes
note() { [ "$QUIET" = yes ] || printf '%s\n' "$*" >&2; }
die()  { printf 'get-pr-preview-endpoint: %s\n' "$*" >&2; exit 1; }

command -v gh >/dev/null 2>&1 || die "needs the GitHub CLI (gh) authenticated. https://cli.github.com"

# ── auto-detect repo + PR from context ───────────────────────────────────────
# In GitHub Actions, prefer the event env; otherwise ask gh about the checkout.
[ -n "$REPO" ] || REPO="${GITHUB_REPOSITORY:-}"
[ -n "$REPO" ] || REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)"
[ -n "$REPO" ] || die "could not determine repo; pass --repo <org/repo>"

if [ -z "$PR" ]; then
  # GITHUB_REF like refs/pull/<n>/merge in Actions, else the PR for the branch.
  case "${GITHUB_REF:-}" in refs/pull/*) PR="$(echo "$GITHUB_REF" | cut -d/ -f3)";; esac
  [ -n "$PR" ] || PR="$(gh pr view --repo "$REPO" --json number -q .number 2>/dev/null)"
fi
[ -n "$PR" ] || die "could not determine PR number; pass --pr <n>"
[[ "$PR" =~ ^[0-9]+$ ]] || die "PR must be a number (got '$PR')"

ENV="preview/pr-$PR"

# ── onboarding probe (shared by --doctor and the richer exit reasons) ────────
# "Onboarded" == a workflow file in the repo's default branch calls the
# platform's reusable preview.yml. We check the repo's contents API (works
# without a checkout), and treat ANY preview/pr-* deployment EVER as proof too.
ONBOARDED=unknown   # yes | no | unknown
onboarding_probe() {
  local names f content
  names="$(gh api "repos/$REPO/contents/.github/workflows" --jq '.[].name' 2>/dev/null)"
  if [ -z "$names" ]; then ONBOARDED=unknown; return; fi
  for f in $names; do
    content="$(gh api "repos/$REPO/contents/.github/workflows/$f" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null)"
    case "$content" in *preview.yml*|*preview/pr-*) ONBOARDED=yes; return;; esac
  done
  # Fallback: a preview/pr-* deployment ever written is hard proof of onboarding.
  local any
  any="$(gh api "repos/$REPO/deployments?per_page=100" --jq '[.[]|select(.environment|startswith("preview/pr-"))]|length' 2>/dev/null)"
  [ -n "$any" ] && [ "$any" != "0" ] && { ONBOARDED=yes; return; }
  ONBOARDED=no
}

# ── resolution (one shot) ────────────────────────────────────────────────────
# Sets RESOLVED_STATE and RESOLVED_URL in the CURRENT shell (not a subshell, so
# state survives). Returns 0 only when a ready URL is found. RESOLVED_STATE is an
# actionable reason on failure (see EXIT REASONS in the header).
RESOLVED_STATE=""; RESOLVED_URL=""
resolve_once() {
  RESOLVED_URL=""
  local dep_id state url concl
  dep_id="$(gh api "repos/$REPO/deployments?environment=$ENV&per_page=1" --jq '.[0].id' 2>/dev/null)"
  if [ -z "$dep_id" ] || [ "$dep_id" = "null" ]; then
    # No deployment for this env — distinguish "never onboarded" from "onboarded
    # but not built yet" so the reason is actionable.
    [ "$ONBOARDED" = unknown ] && onboarding_probe
    RESOLVED_STATE=$([ "$ONBOARDED" = no ] && echo "not-onboarded" || echo "no-deployment-yet")
    return 1
  fi
  state="$(gh api "repos/$REPO/deployments/$dep_id/statuses?per_page=1" --jq '.[0].state // empty' 2>/dev/null)"
  url="$(gh api "repos/$REPO/deployments/$dep_id/statuses?per_page=1" --jq '.[0].environment_url // empty' 2>/dev/null)"

  # SHA gate: require the `preview` Check Run for THIS sha to be
  # success before trusting the (reused) URL.
  if [ -n "$SHA" ]; then
    concl="$(gh api "repos/$REPO/commits/$SHA/check-runs" \
      --jq '[.check_runs[]|select(.name=="preview")]|sort_by(.started_at)|last|.conclusion' 2>/dev/null)"
    [ "$concl" = "success" ] || { RESOLVED_STATE="awaiting-sha:${concl:-none}"; return 1; }
  fi

  if [ "$state" != "success" ]; then RESOLVED_STATE="deploy-pending:${state:-unknown}"; return 1; fi
  if [ -z "$url" ]; then RESOLVED_STATE="deployment-no-url"; return 1; fi
  RESOLVED_STATE="success"; RESOLVED_URL="$url"; return 0
}

emit() { # emit <url>
  if [ "$JSON" = yes ]; then
    printf '{"url":"%s","state":"%s","repo":"%s","pr":%s,"sha":"%s"}\n' "$1" "$RESOLVED_STATE" "$REPO" "$PR" "$SHA"
  else
    printf '%s\n' "$1"
  fi
}

# ── --doctor: diagnose the chain, print the exact missing link, exit 0 ───────
# This exists because using the skill cold required manual discovery ("is there a
# cluster? is the repo onboarded? why no-deployment?"). Doctor answers all of it.
if [ "$DOCTOR" = yes ]; then
  printf '── get-pr-preview-endpoint doctor: %s PR #%s ──\n' "$REPO" "$PR"
  # 1) gh auth
  if gh auth status >/dev/null 2>&1; then echo "✓ gh authenticated"; else echo "✗ gh NOT authenticated — run: gh auth login"; fi
  # 2) onboarding
  onboarding_probe
  case "$ONBOARDED" in
    yes)     echo "✓ repo onboarded (a workflow calls the reusable preview.yml, or a preview/pr-* deployment exists)";;
    no)      echo "✗ repo NOT onboarded — no workflow calls pr-preview's preview.yml. Add a 5-line caller (see the platform's onboarding docs).";;
    unknown) echo "? onboarding unknown — could not read .github/workflows (token scope or path).";;
  esac
  # 3) the deployment for THIS PR
  dep_id="$(gh api "repos/$REPO/deployments?environment=$ENV&per_page=1" --jq '.[0].id' 2>/dev/null)"
  if [ -n "$dep_id" ] && [ "$dep_id" != "null" ]; then
    dstate="$(gh api "repos/$REPO/deployments/$dep_id/statuses?per_page=1" --jq '.[0].state // "none"' 2>/dev/null)"
    durl="$(gh api "repos/$REPO/deployments/$dep_id/statuses?per_page=1" --jq '.[0].environment_url // "none"' 2>/dev/null)"
    echo "✓ deployment exists for $ENV (state=$dstate url=$durl)"
  else
    echo "✗ no GitHub Deployment for $ENV yet" \
         "$([ "$ONBOARDED" = yes ] && echo '— onboarded, so the preview just has not built (push a commit / wait for the preview workflow).' || echo '— expected, since the repo is not onboarded.')"
  fi
  # 4) SHA freshness (only if asked)
  if [ -n "$SHA" ]; then
    concl="$(gh api "repos/$REPO/commits/$SHA/check-runs" --jq '[.check_runs[]|select(.name=="preview")]|sort_by(.started_at)|last|.conclusion // "none"' 2>/dev/null)"
    echo "  preview Check Run for $SHA: ${concl:-none} (need: success)"
  fi
  # 5) bottom line
  resolve_once || true
  echo "→ resolver state: $RESOLVED_STATE${RESOLVED_URL:+  url=$RESOLVED_URL}"
  exit 0
fi

note "resolving preview for $REPO PR #$PR (env $ENV)${SHA:+ @ $SHA}…"
deadline=$(( $(date +%s) + WAIT ))
while :; do
  if resolve_once; then note "ready: $RESOLVED_URL"; emit "$RESOLVED_URL"; exit 0; fi
  [ "$(date +%s)" -lt "$deadline" ] || break
  note "  not ready ($RESOLVED_STATE); retrying…"; sleep 5
done

note "no ready preview URL ($RESOLVED_STATE)"
[ "$JSON" = yes ] && emit ""
exit 1
