#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# strip-pr-footer.sh — remove the "🤖 Generated with [Claude Code]" footer from
# PR descriptions on a repo. ABCA's agent runs its own inner claude-code to open
# the PR, so that instance appends the footer regardless of your local
# ~/.claude/settings.json. The going-forward fix is the attribution block in
# ABCA's managed-settings.json (rebuild the agent image); this cleans PRs that
# were opened by an image built before that patch.
#
# Usage:  REPO=owner/repo strip-pr-footer.sh [pr-number ...]
#         (no args → all open PRs)
set -uo pipefail
: "${REPO:?set REPO=owner/repo}"
prs="$*"
[ -n "$prs" ] || prs="$(gh pr list --repo "$REPO" --state open --json number --jq '.[].number' 2>/dev/null)"
n=0
for pr in $prs; do
  body="$(gh pr view "$pr" --repo "$REPO" --json body --jq '.body' 2>/dev/null)"
  printf '%s' "$body" | grep -qiE "Generated with .*Claude Code|🤖" || continue
  new="$(printf '%s' "$body" | perl -0pe 's/\n*🤖 Generated with \[Claude Code\]\([^)]*\)\s*$//i')"
  gh pr edit "$pr" --repo "$REPO" --body "$new" >/dev/null 2>&1 && { echo "stripped PR #$pr"; n=$((n+1)); }
done
echo "stripped $n PR(s)"
