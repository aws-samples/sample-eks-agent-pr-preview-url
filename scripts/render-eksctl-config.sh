#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# render-eksctl-config.sh — fill eksctl/eksctl-cluster.yaml from CDK stack outputs.
#
# Prereq: `cdk deploy <Network> <Data> <Cicd>` has run (the CDK stack that owns
# the VPC exports VpcId / PrivateSubnetIds / PublicSubnetIds / AvailabilityZones).
#
# Usage:  source project.env && ./scripts/render-eksctl-config.sh
# Output: eksctl/eksctl-cluster.rendered.yaml  (then: eksctl create cluster -f it)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=project.env
[ -f "$ROOT/project.env" ] && source "$ROOT/project.env"

PROJECT_NAME="${PROJECT_NAME:-pr-preview}"
AWS_REGION="${AWS_REGION:-us-east-1}"

# Network stack id = PascalCase(project_name) + "Network" (matches infra/bin/infra.ts).
NET_STACK="$(printf '%s' "$PROJECT_NAME" | awk -F'[^a-zA-Z0-9]+' '{for(i=1;i<=NF;i++){printf "%s%s",toupper(substr($i,1,1)),substr($i,2)}}')Network"

out() { # out <OutputKey>
  aws cloudformation describe-stacks --stack-name "$NET_STACK" --region "$AWS_REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}

echo "[render] reading outputs from stack $NET_STACK ($AWS_REGION)..." >&2
VPC_ID="$(out VpcId)"
AZS="$(out AvailabilityZones)"
PRIV="$(out PrivateSubnetIds)"
PUB="$(out PublicSubnetIds)"
[ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ] || { echo "[render] no VpcId — did you 'cdk deploy $NET_STACK'?" >&2; exit 1; }

# Build the eksctl vpc.subnets.{private,public} blocks, one entry per AZ.
# eksctl keys each subnet by its AZ; CDK returns AZs + subnet ids in matching order.
subnet_block() { # subnet_block <comma-azs> <comma-subnet-ids>
  local IFS=','; read -ra azs <<< "$1"; read -ra ids <<< "$2"
  local i
  for i in "${!ids[@]}"; do
    printf '      %s: { id: "%s" }\n' "${azs[$i]}" "${ids[$i]}"
  done
}
PRIVATE_SUBNETS="$(subnet_block "$AZS" "$PRIV")"
PUBLIC_SUBNETS="$(subnet_block "$AZS" "$PUB")"

TEMPLATE="$ROOT/eksctl/eksctl-cluster.yaml"
RENDERED="$ROOT/eksctl/eksctl-cluster.rendered.yaml"

# Substitute placeholders line-by-line (portable; the multiline subnet blocks are
# emitted where their placeholder line appears — no multiline awk/sed vars).
: > "$RENDERED"
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    *'{{PRIVATE_SUBNETS}}'*) printf '%s\n' "$PRIVATE_SUBNETS" >> "$RENDERED"; continue ;;
    *'{{PUBLIC_SUBNETS}}'*)  printf '%s\n' "$PUBLIC_SUBNETS"  >> "$RENDERED"; continue ;;
  esac
  line="${line//\{\{PROJECT_NAME\}\}/$PROJECT_NAME}"
  line="${line//\{\{AWS_REGION\}\}/$AWS_REGION}"
  line="${line//\{\{VPC_ID\}\}/$VPC_ID}"
  printf '%s\n' "$line" >> "$RENDERED"
done < "$TEMPLATE"

echo "[render] wrote $RENDERED" >&2
echo "[render] next: eksctl create cluster -f $RENDERED" >&2
