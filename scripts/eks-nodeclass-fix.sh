#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# Point the EKS Auto Mode `default` NodeClass at the pre-created instance profile.
#
# Auto Mode seeds a `default` NodeClass that uses `role:` and auto-creates the
# instance profile — which fails to attach a custom node role (see
# docs/runbook.md (opt-in CDK cluster path)). This swaps it to reference the CDK-created profile via
# `instanceProfile:` and the live cluster security group, which makes node
# provisioning work.
#
# Run once after `cdk deploy` + `aws eks update-kubeconfig`.
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"
CLUSTER="${CLUSTER:-pr-preview}"
PROFILE="${NODE_INSTANCE_PROFILE:-pr-preview-nodes}"

CLUSTER_SG="$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)"
VPC="$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)"
# bash 3.2 (macOS) has no mapfile; use a plain word-split list.
SUBNETS="$(aws ec2 describe-subnets --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC" "Name=tag:aws-cdk:subnet-type,Values=Private" \
  --query 'Subnets[].SubnetId' --output text | tr '\t' '\n')"

echo "cluster SG: $CLUSTER_SG"
echo "subnets: $SUBNETS"

subnet_terms=""
for s in $SUBNETS; do subnet_terms+="    - id: ${s}"$'\n'; done

kubectl delete nodeclass default --ignore-not-found --wait=true --timeout=90s || true
cat <<YAML | kubectl apply -f -
apiVersion: eks.amazonaws.com/v1
kind: NodeClass
metadata:
  name: default
spec:
  instanceProfile: ${PROFILE}
  ephemeralStorage: { iops: 3000, size: 80Gi, throughput: 125 }
  networkPolicy: DefaultAllow
  snatPolicy: Random
  securityGroupSelectorTerms:
    - id: ${CLUSTER_SG}
  subnetSelectorTerms:
${subnet_terms}
YAML

echo "applied. Watching for Ready..."
for _ in $(seq 1 12); do
  sleep 20
  ready="$(kubectl get nodeclass default -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null)"
  echo "  Ready=$ready"
  [ "$ready" = "True" ] && { echo "NodeClass Ready"; break; }
done
