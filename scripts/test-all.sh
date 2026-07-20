#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# Run the full non-cluster test suite (unit + render + typecheck + e2e).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
run() { echo "=== $1 ==="; shift; "$@" || fail=1; echo; }

run "bash lib unit"   bash tests/bash-lib.test.sh
run "reaper guards"   bash tests/preview-sweep.test.sh
run "cf url signer"   bash tests/cf-sign-url.test.sh
run "app unit"        bash -c "cd app && npm test"
run "skill unit"      bash -c "cd skills/preview-iterate && npm test"
run "helm render"     bash tests/helm-render.test.sh
run "app typecheck"   bash -c "cd app && npm run typecheck"
run "infra typecheck" bash -c "cd infra && npm run typecheck"
run "infra cdk tests" bash -c "cd infra && JSII_SILENCE_WARNING_UNTESTED_NODE_VERSION=1 npm test"
run "native e2e"      node e2e/native-e2e.mjs
run "db isolation"    node e2e/db-isolation.mjs   # skips cleanly without DATABASE_URL

if [ "$fail" -eq 0 ]; then echo "ALL SUITES PASSED"; else echo "SOME SUITES FAILED"; fi
exit "$fail"
