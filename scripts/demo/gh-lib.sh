#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# gh-lib.sh — small shared helpers for the ABCA demo scripts.
#
# Sourced (not executed) by abca-preview-controller.sh, test-preview.sh,
# screenshot-preview.sh, and test-task-e2e-batch.sh so the hardened GitHub-API
# access lives in ONE place. Portable to macOS bash 3.2 (no bash-4 features).
#
# WHY: `gh api` intermittently returns an error-JSON (rate-limit, or a transient
# "No server is currently available…" body) instead of the requested field. Used
# verbatim, that garbage poisons downstream logic — e.g. a head SHA of `{"messa…`
# fed to `docker build --build-arg GIT_SHA=…` fails the build, or an error message
# extracted as the "expected page text" causes a bogus content failure. These
# helpers validate the shape and retry before returning.

# pr_head_sha REPO PR — echo the 7-char hex short SHA of a PR's head, or return 1.
# Validates the result is exactly 7 hex chars (rejecting error-JSON) and retries a
# few times on a transient blip.
pr_head_sha() {
  local repo="$1" pr="$2" raw short _t
  for _t in 1 2 3; do
    raw="$(gh api "repos/$repo/pulls/$pr" --jq '.head.sha' 2>/dev/null)"
    short="$(printf '%s' "$raw" | cut -c1-7)"
    case "$short" in
      [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) printf '%s' "$short"; return 0;;
    esac
    sleep $(( _t * 3 ))
  done
  return 1
}

# pr_title REPO PR — echo a PR's title, or empty if it can't be resolved to a real
# title (an error-JSON is rejected so its "message" can't be mistaken for content).
pr_title() {
  local repo="$1" pr="$2" title _t
  for _t in 1 2 3; do
    title="$(gh api "repos/$repo/pulls/$pr" --jq '.title' 2>/dev/null)"
    case "$title" in
      ''|'{'*'"message"'*|*'"documentation_url"'*|*'currently available to service'*) sleep $(( _t * 2 ));;
      *) printf '%s' "$title"; return 0;;
    esac
  done
  return 1
}
