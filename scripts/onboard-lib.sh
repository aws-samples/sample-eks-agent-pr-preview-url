#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# onboard-lib.sh — pure helpers for onboard-app.sh, sourced by both the script
# and tests/bash-lib.test.sh. No side effects at source time; bash 3.2 safe.

# onboard_mode_for <basepath_404> <serves_root>
#   Decide routing mode from probe results:
#   - app serves at "/" (root 200) and 404s "/pr-N"  → host  (no basePath baked)
#   - app serves under "/pr-N"                        → path  (basePath baked)
# Args are "yes"/"no".
onboard_mode_for() {
  local serves_basepath="$1" serves_root="$2"
  if [ "$serves_basepath" = "yes" ]; then echo "path"; return; fi
  if [ "$serves_root" = "yes" ]; then echo "host"; return; fi
  # Unknown — default to host (serves at /, the safer assumption for arbitrary images).
  echo "host"
}

# onboard_readiness_for <health_has_sha>
#   "sha" if /api/health returns a sha field (strict SHA gate),
#   else "probe" (probe-only readiness). Arg is "yes"/"no".
onboard_readiness_for() {
  [ "$1" = "yes" ] && echo "sha" || echo "probe"
}

# onboard_ns_for <pr>  → preview namespace
onboard_ns_for() { echo "pr-$1"; }

# onboard_host_for <pr> <baseDomain>  → host-mode hostname
onboard_host_for() { echo "pr-$1.$2"; }

# onboard_ecr_repo_for <org/app>  → conventional preview ECR repo path
onboard_ecr_repo_for() { echo "${1#*/}/preview"; }

# onboard_valid_pr <n>  → 0 if a positive integer
onboard_valid_pr() { [[ "$1" =~ ^[0-9]+$ ]]; }

# onboard_is_preview_ns <name>  → 0 only for pr-<n> preview namespaces.
# The guard that prevents offboarding from ever touching example-app-prod, kube-*,
# external-secrets, etc.
onboard_is_preview_ns() { [[ "$1" =~ ^pr-[0-9]+$ ]]; }
