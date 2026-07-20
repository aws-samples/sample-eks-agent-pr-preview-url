#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# onboard-app.sh — one-step onboarding for the PR-preview platform.
#
# Two modes:
#   image  — deploy an already-built image / in-cluster app as a live preview,
#            auto-detecting port, routing mode (host vs path), health-sha gate,
#            and copying a secret. (The example-app path, scripted.)
#   repo   — scaffold an app repo onto the platform: generate caller workflows,
#            print the secret command, and run a contract check.
#
# Usage:
#   onboard-app.sh image --image <ecr-ref:tag> --pr <n> [--secret <k8s-secret>]
#                        [--base-domain <d>] [--ns <ns>] [--port <p>]
#   onboard-app.sh repo  --repo <org/app> [--routing path|host] [--out <dir>]
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Load project config (project_name/github_org/aws_region + derived names).
# shellcheck source=project.env
[ -f "$ROOT/project.env" ] && source "$ROOT/project.env"
# shellcheck source=scripts/onboard-lib.sh
source "$ROOT/scripts/onboard-lib.sh"
CHART="$ROOT/charts/preview-env"
RELEASE="web"
PROJECT_NAME="${PROJECT_NAME:-pr-preview}"
# CloudFormation CICD stack id — must match the CDK stackId() derivation in
# infra/bin/infra.ts (PascalCase(project_name) + "Cicd").
CICD_STACK="$(printf '%s' "$PROJECT_NAME" | awk -F'[^a-zA-Z0-9]+' '{for(i=1;i<=NF;i++){printf "%s%s",toupper(substr($i,1,1)),substr($i,2)}}')Cicd"

log() { printf '\033[36m[onboard]\033[0m %s\n' "$*" >&2; }
err() { printf '\033[31m[onboard:err]\033[0m %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

# bash 3.2 safe (no associative arrays). Args are kept verbatim in ARGV; arg()
# looks up a --flag's value. argflag() tests presence.
ARGV=()
arg() { # arg <name> [default] — value of --name
  local i nxt; for ((i=0; i<${#ARGV[@]}; i++)); do
    if [ "${ARGV[$i]}" = "--$1" ]; then
      nxt="${ARGV[$((i+1))]:-}"
      # Guard: a missing value must not swallow the following --flag.
      case "$nxt" in --*) nxt="";; esac
      echo "$nxt"; return
    fi
  done; echo "${2:-}"
}
argflag() { # argflag --name — 0 if the bare flag is present
  local a; for a in "${ARGV[@]:-}"; do [ "$a" = "$1" ] && return 0; done; return 1
}

# ── image mode ──────────────────────────────────────────────────────────────
cmd_image() {
  local image pr secret secret_ns ns base port repo tag
  image="$(arg image)"; pr="$(arg pr)"; secret="$(arg secret)"
  secret_ns="$(arg secret-ns)"
  ns="$(arg ns)"; base="$(arg base-domain preview.local)"; port="$(arg port)"
  [ -n "$image" ] || die "image mode needs --image <ecr-ref:tag>"
  onboard_valid_pr "$pr" || die "image mode needs --pr <positive int>"
  ns="${ns:-$(onboard_ns_for "$pr")}"
  # Split the image ref into repo+tag up front so a missing/odd tag is caught
  # (a registry-port ref like host:5000/repo without a tag would mis-split).
  case "$image" in
    */*:* | *:*) if [[ "${image##*/}" == *:* ]]; then repo="${image%:*}"; tag="${image##*:}"; else repo="$image"; tag=""; fi ;;
    *) repo="$image"; tag="" ;;
  esac
  [ -n "$tag" ] || die "image needs an explicit :tag (got '$image') — refuse to guess"

  log "probing image $image (port / routing / health-sha)…"
  # Probe in a throwaway pod in the target ns.
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
  kubectl label namespace "$ns" app.kubernetes.io/part-of=preview-platform \
    "preview.pr-preview/pr-number=$pr" --overwrite >/dev/null 2>&1
  kubectl -n "$ns" delete pod onboard-probe --ignore-not-found >/dev/null 2>&1
  kubectl -n "$ns" run onboard-probe --image="$image" --restart=Never \
    --port="${port:-3000}" >/dev/null 2>&1 || true
  kubectl -n "$ns" wait --for=condition=ready pod/onboard-probe --timeout=90s >/dev/null 2>&1 || true

  # Detect port (from the image's first containerPort if not given).
  if [ -z "$port" ]; then
    port="$(kubectl -n "$ns" get pod onboard-probe -o jsonpath='{.spec.containers[0].ports[0].containerPort}' 2>/dev/null)"
    port="${port:-3000}"
  fi
  # Probe health at root and at /pr-N, capture sha presence. The probe runs
  # `node` INSIDE the image — verify node exists first so a non-node image isn't
  # silently misdetected as host+probe (caught by code-review).
  local root_json bp_code serves_root=no serves_bp=no has_sha=no probe_ok=no
  if kubectl -n "$ns" exec onboard-probe -- node -e 'typeof fetch==="function"||process.exit(3)' >/dev/null 2>&1; then
    probe_ok=yes
    root_json="$(kubectl -n "$ns" exec onboard-probe -- node -e "fetch('http://localhost:$port/api/health').then(r=>r.ok?r.text():'').then(t=>process.stdout.write(t)).catch(()=>{})" 2>/dev/null)"
    [ -n "$root_json" ] && serves_root=yes
    echo "$root_json" | grep -q '"sha"' && has_sha=yes
    bp_code="$(kubectl -n "$ns" exec onboard-probe -- node -e "fetch('http://localhost:$port/pr-$pr/api/health').then(r=>process.stdout.write(String(r.status))).catch(()=>process.stdout.write('0'))" 2>/dev/null)"
    [ "$bp_code" = "200" ] && serves_bp=yes
  fi
  kubectl -n "$ns" delete pod onboard-probe --ignore-not-found >/dev/null 2>&1

  local mode readiness
  if [ "$probe_ok" = no ]; then
    err "WARNING: could not probe the image (no node+fetch inside it). Defaulting to"
    err "         routing=host + probe-only readiness. If this app serves under a"
    err "         basePath, pass --routing path explicitly (not auto-detectable here)."
    mode="$(arg routing host)"; readiness=probe
  else
    mode="$(onboard_mode_for "$serves_bp" "$serves_root")"
    readiness="$(onboard_readiness_for "$has_sha")"
  fi
  log "detected: port=$port routing=$mode readiness=$readiness (probe=$probe_ok, health sha: $has_sha)"

  # Secret wiring: actually COPY the named secret from its source namespace into
  # the target ns (stripping namespace-bound metadata), then wire every key as a
  # secretKeyRef env. Source defaults to the current-context namespace.
  local extra_env_json='[]'
  if [ -n "$secret" ]; then
    secret_ns="${secret_ns:-$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null)}"
    secret_ns="${secret_ns:-default}"
    log "copying secret $secret from ns $secret_ns into $ns and wiring its keys as env"
    if kubectl get secret "$secret" -n "$secret_ns" -o json >/dev/null 2>&1; then
      kubectl get secret "$secret" -n "$secret_ns" -o json \
        | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{const o=JSON.parse(s);o.metadata={name:o.metadata.name,namespace:'$ns'};delete o.status;process.stdout.write(JSON.stringify(o))})" \
        | kubectl apply -f - >/dev/null 2>&1 || err "WARNING: failed to copy secret $secret into $ns"
    else
      err "WARNING: secret '$secret' not found in ns '$secret_ns' (set --secret-ns); deploying without it"
    fi
    # Build extraEnv from the secret's keys (each → secretKeyRef) now that it's in $ns.
    extra_env_json="$(kubectl get secret "$secret" -n "$ns" -o json 2>/dev/null | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{try{const k=Object.keys(JSON.parse(s).data||{});process.stdout.write(JSON.stringify(k.map(n=>({name:n,valueFrom:{secretKeyRef:{name:'$secret',key:n}}}))))}catch{process.stdout.write('[]')}})" 2>/dev/null)"
    extra_env_json="${extra_env_json:-[]}"
    [ "$extra_env_json" = '[]' ] && err "WARNING: no keys wired from secret $secret (empty or absent in $ns)"
  fi

  log "helm upgrade --install $RELEASE -n $ns (mode=$mode)"
  local helm_args=(upgrade --install "$RELEASE" "$CHART" --namespace "$ns" --wait --timeout 4m
    --set prNumber="$pr" --set routing.mode="$mode" --set routing.ingressClassName=alb
    --set externalSecret.enabled=false --set image.repository="$repo"
    --set image.tag="$tag" --set image.pullPolicy=IfNotPresent
    # networkPolicy off here on purpose: onboard-app is a quick smoke-deploy that
    # may target clusters with no NP enforcement (kind without a CNI plugin), where
    # a default-deny would silently drop probes. The golden-path preview.yml keeps
    # the chart default (on) — verified to coexist with the shared ALB on EKS Auto Mode.
    --set service.targetPort="$port" --set guardrails.networkPolicy.enabled=false)
  [ "$mode" = host ] && helm_args+=(--set routing.baseDomain="$base")
  [ "$extra_env_json" != '[]' ] && helm_args+=(--set-json "extraEnv=$extra_env_json")
  helm "${helm_args[@]}" >&2 || die "helm install failed (see above)"

  # Report the preview URL + a browser-friendly port-forward (no DNS).
  local url
  if [ "$mode" = host ]; then url="http://$(onboard_host_for "$pr" "$base")/"; else url="http://<alb>/pr-$pr/"; fi
  log "READY. Preview URL: $url"
  log "Browser access (no DNS): kubectl port-forward -n $ns svc/$RELEASE 8$pr:80  then open http://localhost:8$pr/"
  echo "ONBOARDED pr=$pr ns=$ns mode=$mode port=$port readiness=$readiness url=$url"
}

# ── repo mode ───────────────────────────────────────────────────────────────
cmd_repo() {
  local repo routing out region
  repo="$(arg repo)"; routing="$(arg routing path)"; out="$(arg out .)"
  region="$(arg region "${AWS_REGION:-us-east-1}")"
  [ -n "$repo" ] || die "repo mode needs --repo <org/app>"
  local wf="$out/.github/workflows"; mkdir -p "$wf"
  local ecr; ecr="$(onboard_ecr_repo_for "$repo")"
  # Discover the shared ALB host from any live preview ingress (best-effort).
  local alb; alb="$(kubectl get ingress -A -o jsonpath='{range .items[*]}{.status.loadBalancer.ingress[0].hostname}{"\n"}{end}' 2>/dev/null | grep -m1 elb.amazonaws.com || true)"
  alb="${alb:-your-alb-hostname.elb.amazonaws.com}"

  log "generating caller workflows for $repo (routing=$routing) into $wf"
  sed -e "s#routing_mode: path#routing_mode: $routing#" \
      -e "s#ingress_host_base: https://your-alb-hostname.elb.amazonaws.com#ingress_host_base: https://$alb#" \
      -e "s#pr-preview/app#$ecr#" \
      "$ROOT/examples/app-repo-caller/.github/workflows/preview.yml" > "$wf/preview.yml" 2>/dev/null \
      || cp "$ROOT/examples/app-repo-caller/.github/workflows/preview.yml" "$wf/preview.yml"
  cp "$ROOT/examples/app-repo-caller/.github/workflows/preview-teardown.yml" "$wf/preview-teardown.yml"

  # Resolve the deploy-role ARN from the CDK stack output (best-effort).
  local role; role="$(aws cloudformation describe-stacks --stack-name "$CICD_STACK" --region "$region" \
    --query "Stacks[0].Outputs[?OutputKey=='GithubDeployRoleArn'].OutputValue" --output text 2>/dev/null)"
  role="${role:-arn:aws:iam::<acct>:role/${PROJECT_NAME}-github-deploy}"

  cat >&2 <<EOF

[onboard] Wrote: $wf/preview.yml, $wf/preview-teardown.yml
[onboard] Next steps:
  1) Set the deploy-role secret (org-wide trust already grants this repo):
       gh secret set AWS_DEPLOY_ROLE_ARN --repo $repo -b "$role"
  2) Ensure the app image meets the contract (see docs/onboarding.md):
       - listens on the port you set; serves /api/health
       - returns {"sha": "<build GIT_SHA>"} for the strict fresh-deploy gate (else probe-only)
       - path mode: bake basePath at build (PREVIEW_BASE_PATH); host mode serves at /
       - runs as non-root UID 1000, tolerates read-only rootfs
  3) Open a PR → the reusable workflow deploys a preview and comments the URL.
EOF
  echo "GENERATED repo=$repo routing=$routing ecr=$ecr alb=$alb workflows=$wf"
}

# ── offboard mode ───────────────────────────────────────────────────────────
# Reverses onboarding. Default: tear down the app's pr-* preview
# namespaces + DROP their pr_<n> schemas. Opt-in: --purge-ecr, --repo (remove
# the GitHub secret + caller workflows). Dry-run unless --yes. NEVER touches a
# non-preview namespace (onboard_is_preview_ns guard).
cmd_offboard() {
  local pr repo purge_ecr confirm region
  pr="$(arg pr)"; repo="$(arg repo)"; region="$(arg region us-east-1)"
  argflag --purge-ecr && purge_ecr=yes || purge_ecr=no
  argflag --yes && confirm=yes || confirm=no
  local dry="[DRY-RUN] "; [ "$confirm" = yes ] && dry=""

  # Determine target namespaces.
  local targets=""
  if [ -n "$pr" ]; then
    onboard_valid_pr "$pr" || die "--pr must be a positive integer"
    targets="$(onboard_ns_for "$pr")"
  else
    targets="$(kubectl get ns -l app.kubernetes.io/part-of=preview-platform \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -E '^pr-[0-9]+$' || true)"
  fi
  [ -n "$targets" ] || { log "no preview namespaces to offboard"; echo "OFFBOARDED count=0"; return; }

  local count=0
  for ns in $targets; do
    # Hard guard: only ever act on pr-<n> preview namespaces.
    onboard_is_preview_ns "$ns" || { err "refusing non-preview namespace: $ns"; continue; }
    local n="${ns#pr-}"
    log "${dry}offboard $ns: DROP schema pr_$n, helm uninstall, delete namespace"
    if [ "$confirm" = yes ]; then
      bash "$ROOT/scripts/drop-schema.sh" "$n" "$ns" >/dev/null 2>&1 || true
      helm uninstall "$RELEASE" -n "$ns" >/dev/null 2>&1 || true
      kubectl delete namespace "$ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    fi
    count=$((count+1))
  done

  # Opt-in: purge the app's preview ECR repo.
  if [ "$purge_ecr" = yes ] && [ -n "$repo" ]; then
    local ecr; ecr="$(onboard_ecr_repo_for "$repo")"
    log "${dry}delete ECR repo $ecr (--purge-ecr)"
    [ "$confirm" = yes ] && aws ecr delete-repository --repository-name "$ecr" --region "$region" --force >/dev/null 2>&1 || true
  fi

  # Opt-in: remove the app repo's secret + caller workflows.
  if [ -n "$repo" ]; then
    log "${dry}app-repo cleanup for $repo (org-wide OIDC trust is shared — NOT revoked):"
    log "    gh secret delete AWS_DEPLOY_ROLE_ARN --repo $repo"
    log "    rm .github/workflows/preview.yml .github/workflows/preview-teardown.yml  (in $repo)"
    if [ "$confirm" = yes ]; then
      gh secret delete AWS_DEPLOY_ROLE_ARN --repo "$repo" >/dev/null 2>&1 || log "    (secret delete needs gh auth on $repo)"
    fi
  fi

  [ "$confirm" = yes ] || log "DRY-RUN: re-run with --yes to apply."
  echo "OFFBOARDED count=$count applied=$confirm purge_ecr=$purge_ecr repo=${repo:-none}"
}

# ── dispatch ─────────────────────────────────────────────────────────────────
sub="${1:-}"; shift || true
ARGV=("$@")
case "$sub" in
  image)    cmd_image ;;
  repo)     cmd_repo ;;
  offboard) cmd_offboard ;;
  *) cat >&2 <<EOF
usage:
  onboard-app.sh image    --image <ecr-ref:tag> --pr <n> [--secret <s>] [--secret-ns <ns>] [--routing path|host] [--base-domain <d>] [--ns <ns>] [--port <p>]
  onboard-app.sh repo     --repo <org/app> [--routing path|host] [--out <dir>]
  onboard-app.sh offboard [--pr <n> | (all preview ns)] [--repo <org/app>] [--purge-ecr] [--yes]
                          (dry-run unless --yes; only ever touches pr-<n> namespaces)
EOF
     exit 2 ;;
esac
