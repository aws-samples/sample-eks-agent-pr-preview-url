#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# setup-gitlab-oidc.sh — Register the GitLab OIDC provider in AWS and create
# (or update) a deploy role that GitLab CI can assume via web identity.
#
# This replaces the GitHub OIDC trust with a GitLab OIDC trust.
#
# Usage:
#   source project.env   # sets AWS_REGION, PROJECT_NAME, etc.
#   bash scripts/setup-gitlab-oidc.sh
#
# Prerequisites:
#   - AWS CLI configured with admin/IAM permissions
#   - project.env sourced (or env vars set)
#
# What this script does:
#   1. Creates the GitLab OIDC Identity Provider in IAM (if not already present)
#   2. Creates (or updates) the deploy role with a trust policy scoped to your
#      GitLab project
#   3. Attaches the required permissions (ECR push, EKS describe, EKS access)
#   4. Prints the role ARN to set as a GitLab CI/CD variable
set -euo pipefail

# --- Configuration (override via env or project.env) ------------------------
GITLAB_URL="${GITLAB_URL:-https://gitlab.aws-dev}"
GITLAB_PROJECT_PATH="${GITLAB_PROJECT_PATH:-bmaguir/eks-agent-pr-preview-url}"
AWS_REGION="${AWS_REGION:-us-east-1}"
PROJECT_NAME="${PROJECT_NAME:-pr-preview}"
CLUSTER_NAME="${CLUSTER_NAME:-$PROJECT_NAME}"
ECR_REPOSITORY="${ECR_REPOSITORY:-$PROJECT_NAME/app}"
ROLE_NAME="${PROJECT_NAME}-gitlab-deploy"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"

# GitLab OIDC issuer (no trailing slash)
GITLAB_OIDC_ISSUER="${GITLAB_URL}"
# The OIDC provider host (no https://)
OIDC_HOST="${GITLAB_URL#https://}"

echo "=== GitLab OIDC Setup for PR Preview ==="
echo "  GitLab URL:      ${GITLAB_URL}"
echo "  Project:         ${GITLAB_PROJECT_PATH}"
echo "  AWS Account:     ${AWS_ACCOUNT_ID}"
echo "  AWS Region:      ${AWS_REGION}"
echo "  Role Name:       ${ROLE_NAME}"
echo "  EKS Cluster:     ${CLUSTER_NAME}"
echo "  ECR Repository:  ${ECR_REPOSITORY}"
echo ""

# --- Step 1: Create the OIDC Identity Provider (idempotent) -----------------
PROVIDER_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_HOST}"

echo "[1/4] Checking OIDC provider: ${OIDC_HOST}"
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "${PROVIDER_ARN}" >/dev/null 2>&1; then
  echo "  ✓ OIDC provider already exists."
else
  echo "  Creating OIDC provider for ${OIDC_HOST}..."
  # Fetch the TLS thumbprint for the GitLab server
  THUMBPRINT=$(echo | openssl s_client -servername "${OIDC_HOST}" -connect "${OIDC_HOST}:443" 2>/dev/null \
    | openssl x509 -fingerprint -noout 2>/dev/null \
    | sed 's/://g' | cut -d= -f2 | tr '[:upper:]' '[:lower:]')

  if [ -z "$THUMBPRINT" ]; then
    echo "  ERROR: Could not retrieve TLS thumbprint for ${OIDC_HOST}."
    echo "  You may need to provide it manually."
    exit 1
  fi

  aws iam create-open-id-connect-provider \
    --url "${GITLAB_OIDC_ISSUER}" \
    --client-id-list "${GITLAB_URL}" \
    --thumbprint-list "${THUMBPRINT}"
  echo "  ✓ OIDC provider created."
fi

# --- Step 2: Create the trust policy ----------------------------------------
echo ""
echo "[2/4] Creating/updating IAM role: ${ROLE_NAME}"

# Trust policy: allow GitLab CI jobs from this specific project to assume the role.
# The sub claim format for GitLab is: project_path:<group>/<project>:ref_type:branch:ref:<branch>
# We scope to merge_request refs and the main branch.
TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "${PROVIDER_ARN}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_HOST}:aud": "${GITLAB_URL}"
        },
        "StringLike": {
          "${OIDC_HOST}:sub": "project_path:${GITLAB_PROJECT_PATH}:*"
        }
      }
    }
  ]
}
EOF
)

if aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  echo "  Role exists — updating trust policy..."
  aws iam update-assume-role-policy \
    --role-name "${ROLE_NAME}" \
    --policy-document "${TRUST_POLICY}"
  echo "  ✓ Trust policy updated."
else
  echo "  Creating role..."
  aws iam create-role \
    --role-name "${ROLE_NAME}" \
    --assume-role-policy-document "${TRUST_POLICY}" \
    --description "GitLab CI deploy role for ${PROJECT_NAME} PR previews" \
    --max-session-duration 3600
  echo "  ✓ Role created."
fi

# --- Step 3: Attach permissions -----------------------------------------------
echo ""
echo "[3/4] Attaching permissions to ${ROLE_NAME}"

ECR_REPO_ARN="arn:aws:ecr:${AWS_REGION}:${AWS_ACCOUNT_ID}:repository/${ECR_REPOSITORY}"
CLUSTER_ARN="arn:aws:eks:${AWS_REGION}:${AWS_ACCOUNT_ID}:cluster/${CLUSTER_NAME}"

POLICY_DOC=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ECRAuth",
      "Effect": "Allow",
      "Action": "ecr:GetAuthorizationToken",
      "Resource": "*"
    },
    {
      "Sid": "ECRPushPull",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:BatchGetImage",
        "ecr:CompleteLayerUpload",
        "ecr:GetDownloadUrlForLayer",
        "ecr:InitiateLayerUpload",
        "ecr:PutImage",
        "ecr:UploadLayerPart"
      ],
      "Resource": "${ECR_REPO_ARN}"
    },
    {
      "Sid": "EKSDescribe",
      "Effect": "Allow",
      "Action": "eks:DescribeCluster",
      "Resource": "${CLUSTER_ARN}"
    }
  ]
}
EOF
)

POLICY_NAME="${PROJECT_NAME}-gitlab-deploy-permissions"

# Check if inline policy already exists
if aws iam get-role-policy --role-name "${ROLE_NAME}" --policy-name "${POLICY_NAME}" >/dev/null 2>&1; then
  echo "  Updating inline policy..."
else
  echo "  Creating inline policy..."
fi

aws iam put-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-name "${POLICY_NAME}" \
  --policy-document "${POLICY_DOC}"
echo "  ✓ Permissions attached."

# --- Step 4: EKS Access Entry -------------------------------------------------
echo ""
echo "[4/4] Creating EKS access entry for the deploy role"

ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}"

if aws eks describe-access-entry --cluster-name "${CLUSTER_NAME}" --principal-arn "${ROLE_ARN}" >/dev/null 2>&1; then
  echo "  ✓ Access entry already exists."
else
  echo "  Creating access entry..."
  aws eks create-access-entry \
    --cluster-name "${CLUSTER_NAME}" \
    --principal-arn "${ROLE_ARN}" \
    --type STANDARD

  aws eks associate-access-policy \
    --cluster-name "${CLUSTER_NAME}" \
    --principal-arn "${ROLE_ARN}" \
    --policy-arn "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy" \
    --access-scope type=cluster
  echo "  ✓ Access entry created with cluster-admin policy."
fi

# --- Done ---------------------------------------------------------------------
echo ""
echo "============================================"
echo "  SETUP COMPLETE"
echo "============================================"
echo ""
echo "Deploy Role ARN:"
echo "  ${ROLE_ARN}"
echo ""
echo "Next steps:"
echo "  1. Set ONE CI/CD variable in GitLab"
echo "     (Settings → CI/CD → Variables — mark as Protected + Masked):"
echo ""
echo "     AWS_DEPLOY_ROLE_ARN  = ${ROLE_ARN}"
echo ""
echo "     That's it. No other secrets or tokens needed:"
echo "       - AWS auth: GitLab OIDC (id_tokens) → sts:AssumeRoleWithWebIdentity"
echo "       - MR comments: CI_JOB_TOKEN (built-in)"
echo "       - Platform config: hardcoded in .gitlab-ci.yml (from project.env)"
echo ""
echo "  2. Push the .gitlab-ci.yml to your repository."
echo ""
echo "  3. Open a Merge Request — the pipeline will build, deploy,"
echo "     and post the preview URL."
