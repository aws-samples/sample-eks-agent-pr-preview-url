#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# abca-submit.sh — submit a coding task to ABCA and wait for the PR it opens.
# Scriptable path: Cognito USER_PASSWORD_AUTH → JWT → POST /v1/tasks → poll.
#
# Env: ABCA_STACK (default backgroundagent-dev), AWS_REGION, ABCA_USER, ABCA_PASS,
#      REPO (owner/app the task targets).
# Usage: ./abca-submit.sh "task description text"
set -uo pipefail
REGION="${AWS_REGION:-us-east-1}"
STACK="${ABCA_STACK:-backgroundagent-dev}"
: "${ABCA_USER:?set ABCA_USER}"; : "${ABCA_PASS:?set ABCA_PASS}"; : "${REPO:?set REPO=owner/app}"
DESC="${1:?usage: abca-submit.sh \"task description\"}"

out() { aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text 2>/dev/null; }

API_URL="$(out ApiUrl)"; CLIENT="$(out AppClientId)"
[ -n "$API_URL" ] && [ -n "$CLIENT" ] || { echo "[abca] missing ApiUrl/AppClientId from $STACK" >&2; exit 1; }

TOKEN="$(aws cognito-idp initiate-auth --region "$REGION" --client-id "$CLIENT" \
  --auth-flow USER_PASSWORD_AUTH \
  --auth-parameters "USERNAME=$ABCA_USER,PASSWORD=$ABCA_PASS" \
  --query 'AuthenticationResult.IdToken' --output text 2>/dev/null)"
[ -n "$TOKEN" ] && [ "$TOKEN" != None ] || { echo "[abca] Cognito auth failed" >&2; exit 1; }

echo "[abca] submitting task to $REPO: $DESC" >&2
RESP="$(curl -sS -X POST "$API_URL/tasks" -H "Authorization: $TOKEN" \
  -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg r "$REPO" --arg d "$DESC" '{repo:$r, task_description:$d}')")"
TASK_ID="$(printf '%s' "$RESP" | jq -r '.data.task_id // .task_id // .id // empty')"
[ -n "$TASK_ID" ] || { echo "[abca] submit failed: $RESP" >&2; exit 1; }
echo "[abca] task_id=$TASK_ID — polling for PR…" >&2

# Poll task status until a PR url appears or it terminates.
for _ in $(seq 1 120); do   # up to ~40 min (agent + build)
  T="$(curl -sS "$API_URL/tasks/$TASK_ID" -H "Authorization: $TOKEN")"
  STATUS="$(printf '%s' "$T" | jq -r '.data.status // .status // empty')"
  PR="$(printf '%s' "$T" | jq -r '.data.pr_url // .result.pr_url // .pr_url // empty')"
  echo "[abca] status=$STATUS pr=${PR:-–}" >&2
  [ -n "$PR" ] && { echo "$PR"; exit 0; }
  # On COMPLETED, ABCA's pr_url field can lag (or a task may use a non-default
  # branch). Fall back to the newest open PR whose head branch carries this
  # task id, then to the newest open PR overall.
  if [ "$STATUS" = "COMPLETED" ]; then
    FOUND="$(gh pr list --repo "$REPO" --state open --json number,url,headRefName \
      --jq "[.[] | select(.headRefName | test(\"$TASK_ID\"))] | .[0].url // empty" 2>/dev/null)"
    [ -z "$FOUND" ] && FOUND="$(gh pr list --repo "$REPO" --state open --json number,url \
      --jq 'sort_by(.number) | last | .url // empty' 2>/dev/null)"
    [ -n "$FOUND" ] && { echo "[abca] resolved PR via gh: $FOUND" >&2; echo "$FOUND"; exit 0; }
  fi
  case "$STATUS" in FAILED|CANCELLED|REJECTED) echo "[abca] terminal: $STATUS" >&2; exit 1;; esac
  sleep 20
done
echo "[abca] timed out waiting for PR" >&2; exit 1
