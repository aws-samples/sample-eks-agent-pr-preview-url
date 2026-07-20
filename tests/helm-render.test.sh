#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# Chart render tests — assert the dual routing mode renders correctly.
# Pure `helm template` + grep; no cluster required. Run: bash tests/helm-render.test.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

CHART=charts/preview-env
pass=0; fail=0
check() { # check <description> <expected-substring> <<< "$haystack"
  local desc="$1" needle="$2" hay; hay="$(cat)"
  if grep -qF -- "$needle" <<<"$hay"; then
    echo "  ✓ $desc"; pass=$((pass+1))
  else
    echo "  ✗ $desc — expected to find: $needle"; fail=$((fail+1))
  fi
}
refute() { # refute <description> <forbidden-substring>
  local desc="$1" needle="$2" hay; hay="$(cat)"
  if grep -qF -- "$needle" <<<"$hay"; then
    echo "  ✗ $desc — should NOT contain: $needle"; fail=$((fail+1))
  else
    echo "  ✓ $desc"; pass=$((pass+1))
  fi
}

echo "path mode (pr-42):"
PATHOUT="$(helm template web "$CHART" --set prNumber=42 --set routing.mode=path --set routing.ingressClassName=nginx --set image.tag=sha-abc)"
check "ingress path is /pr-42"        "path: /pr-42"            <<<"$PATHOUT"
check "probe targets /pr-42/api/health" "/pr-42/api/health"     <<<"$PATHOUT"
check "pr-number label set"           'pr-number: "42"'         <<<"$PATHOUT"
check "image tag applied"             "app:sha-abc"             <<<"$PATHOUT"
check "per-PR db schema env (pr_42)"  'value: "pr_42"'          <<<"$PATHOUT"

echo "host mode (pr-42):"
HOSTOUT="$(helm template web "$CHART" --set prNumber=42 --set routing.mode=host --set routing.baseDomain=preview.example.com)"
check "host is pr-42.preview.example.com" "pr-42.preview.example.com" <<<"$HOSTOUT"
check "ingress path is root"          "path: /"                  <<<"$HOSTOUT"
check "probe targets /api/health"     "path: /api/health"        <<<"$HOSTOUT"
refute "no basePath baked in host mode" "/pr-42/api/health"      <<<"$HOSTOUT"

echo "per-commit immutable host (Phase 1):"
COMMITOUT="$(helm template web "$CHART" --set prNumber=42 --set routing.mode=host --set routing.baseDomain=preview.example.com --set commitSha=abc1234)"
check "host mode + commitSha renders commit host" "pr-42-abc1234.preview.example.com" <<<"$COMMITOUT"
refute "no commit host without a commitSha"       "pr-42-abc1234"  <<<"$HOSTOUT"
PATHCOMMIT="$(helm template web "$CHART" --set prNumber=42 --set routing.mode=path --set routing.ingressClassName=alb --set commitSha=abc1234)"
refute "path mode never renders a host (commit or branch)" "host:" <<<"$PATHCOMMIT"

echo "security hardening:"
check "runAsNonRoot"                  "runAsNonRoot: true"       <<<"$PATHOUT"
check "readOnlyRootFilesystem"        "readOnlyRootFilesystem: true" <<<"$PATHOUT"
check "drop ALL caps"                 'drop: ["ALL"]'            <<<"$PATHOUT"
# numeric runAsUser is REQUIRED: a non-numeric image USER (node) fails the
# kubelet's runAsNonRoot check with CreateContainerConfigError (caught live).
check "numeric runAsUser pinned"      "runAsUser: 1000"          <<<"$PATHOUT"

echo "namespace guardrails (Phase 2):"
GUARD="$(helm template web "$CHART" --set prNumber=42 --set routing.mode=path --set routing.ingressClassName=alb)"
check "ResourceQuota rendered"        "kind: ResourceQuota"      <<<"$GUARD"
check "LimitRange rendered"           "kind: LimitRange"         <<<"$GUARD"
check "NetworkPolicy rendered"        "kind: NetworkPolicy"      <<<"$GUARD"
check "PodDisruptionBudget rendered"  "kind: PodDisruptionBudget" <<<"$GUARD"
check "quota caps pods"               "pods:"                    <<<"$GUARD"
check "egress allows the db port"     "port: 5432"               <<<"$GUARD"
# Tenant isolation: NetworkPolicy ingress must admit ONLY the ingress-controller
# namespaces, NOT the shared preview-platform label (which every preview carries →
# would let any preview reach any other). Extract just the ingress `from:` block
# and assert it selects by namespace NAME, not by the shared part-of label.
# Slice just the ingress `ingress:`→`ports:` rule block (the `from:` selectors),
# dropping comments, so we test the real selector — not the chart's own label
# metadata or the explanatory comment that names the label it avoids.
NP_INGRESS_FROM="$(printf '%s\n' "$GUARD" | awk '/^  ingress:/{f=1} f&&/^      ports:/{print;exit} f' | sed 's/#.*//')"
refute "NP ingress not open to all previews (no part-of selector)" "part-of: preview-platform" <<<"$NP_INGRESS_FROM"
check "NP ingress = controller namespaces" "kubernetes.io/metadata.name" <<<"$NP_INGRESS_FROM"
# Egress DB port must be destination-scoped (an ipBlock present), not bare ports.
check "NP egress db port is CIDR-scoped" "ipBlock:"             <<<"$GUARD"
SCOPED="$(helm template web "$CHART" --set prNumber=42 --set routing.mode=path --set routing.ingressClassName=alb --set guardrails.networkPolicy.dbEgressCidr=10.20.0.0/16)"
check "NP egress honors dbEgressCidr" 'cidr: "10.20.0.0/16"'    <<<"$SCOPED"
NOGUARD="$(helm template web "$CHART" --set prNumber=42 --set routing.mode=path --set routing.ingressClassName=alb --set guardrails.resourceQuota.enabled=false --set guardrails.networkPolicy.enabled=false --set guardrails.limitRange.enabled=false --set guardrails.podDisruptionBudget.enabled=false)"
refute "guardrails fully toggleable off" "kind: ResourceQuota"   <<<"$NOGUARD"

echo "preview access protection (Phase 4):"
PROT="$(helm template web "$CHART" --set prNumber=42 --set routing.mode=path --set routing.ingressClassName=alb --set protect.enabled=true --set protect.oidc.issuer=https://idp.example.com)"
check "protect on adds ALB oidc auth"  "auth-type: oidc"         <<<"$PROT"
check "protect on authenticates unauth" "auth-on-unauthenticated-request: authenticate" <<<"$PROT"
refute "public by default (no auth)"   "auth-type: oidc"         <<<"$PATHOUT"

echo "external secret toggle:"
ESOOUT="$(helm template web "$CHART" --set prNumber=42 --set externalSecret.enabled=true)"
check "ExternalSecret rendered"       "kind: ExternalSecret"     <<<"$ESOOUT"
NOESO="$(helm template web "$CHART" --set prNumber=42)"
refute "no ExternalSecret by default" "kind: ExternalSecret"     <<<"$NOESO"

echo "optional basic auth:"
AUTHOUT="$(helm template web "$CHART" --set prNumber=42 --set basicAuth.enabled=true)"
check "BASIC_AUTH_B64 env wired"      "name: BASIC_AUTH_B64"     <<<"$AUTHOUT"
check "basic-auth secret referenced"  "web-basic-auth"           <<<"$AUTHOUT"
NOAUTH="$(helm template web "$CHART" --set prNumber=42)"
refute "no basic-auth env by default" "BASIC_AUTH_B64"           <<<"$NOAUTH"

echo "values.schema.json rejects bad values (fail-fast):"
schema_rejects() { # <description> <helm --set args...>
  local desc="$1"; shift
  if helm template web "$CHART" --set prNumber=42 --set routing.ingressClassName=alb "$@" >/dev/null 2>&1; then
    echo "  ✗ $desc — schema did NOT reject"; fail=$((fail+1))
  else
    echo "  ✓ $desc"; pass=$((pass+1))
  fi
}
schema_rejects "bad routing.mode (enum) is rejected"          --set routing.mode=hostt
schema_rejects "host mode with blank baseDomain is rejected"  --set routing.mode=host --set routing.baseDomain=""
# and a KNOWN-GOOD render still succeeds (guards against an over-strict schema)
if helm template web "$CHART" --set prNumber=42 --set routing.mode=path --set routing.ingressClassName=alb >/dev/null 2>&1; then
  echo "  ✓ valid values still render under the schema"; pass=$((pass+1))
else
  echo "  ✗ valid values REJECTED by the schema (too strict)"; fail=$((fail+1))
fi

echo
echo "helm-render: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
