#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# provision-cloudfront-frontdoor.sh — stand up the opt-in CloudFront front-door
# (signed URLs over a private ALB) reproducibly. Idempotent-ish: safe to re-read,
# prints the ids to add to project.local.env.
#
# Prereqs: the platform deployed on EKS Auto Mode; the `alb-internal` IngressClass
# applied (charts/preview-env/alb-ingressclass.yaml); a keepalive Ingress on that
# class so the internal ALB group is warm and its ARN is stable (see
# docs/design-cloudfront-frontdoor.md — "keep the internal ALB group warm").
#
# Why a script and not pure CDK: a CloudFront VPC Origin must reference a LIVE ALB
# ARN, and the Auto Mode group ALB is created lazily by the controller — so the
# ordering (deploy an internal Ingress → read the ALB ARN → create the VPC origin
# → create the distribution) doesn't fit a single synth. This captures those steps.
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"
SECRET_ID="${CF_SIGNING_SECRET:-pr-preview/cloudfront-signing-key}"
CACHING_DISABLED="4135ea2d-6df8-44a3-9df3-4b5a84be39ad"   # managed CachingDisabled
ALL_VIEWER="216adef6-5c7f-47e4-b989-5492eafa07d3"         # managed AllViewer
log() { printf '\033[36m[cf]\033[0m %s\n' "$*" >&2; }

# 1. internal ALB ARN (the alb-internal group must already have a warm Ingress).
INT_ARN="$(aws elbv2 describe-load-balancers --region "$REGION" \
  --query "LoadBalancers[?Scheme=='internal']|[0].LoadBalancerArn" --output text)"
[ "$INT_ARN" != None ] && [ -n "$INT_ARN" ] || { echo "no internal ALB — deploy a keepalive Ingress on alb-internal first" >&2; exit 1; }
log "internal ALB: $INT_ARN"

# 2. signing key pair → public key + key group in CloudFront; private key to Secrets Manager.
KEY="$(mktemp)"; PUB="$(mktemp)"; trap 'rm -f "$KEY" "$PUB"' EXIT
openssl genrsa -out "$KEY" 2048 2>/dev/null
openssl rsa -pubout -in "$KEY" -out "$PUB" 2>/dev/null
PK_ID="$(aws cloudfront create-public-key --region "$REGION" \
  --public-key-config "$(jq -nc --arg k "$(cat "$PUB")" '{CallerReference:("pr-preview-"+ (now|tostring)), Name:"pr-preview-signing", EncodedKey:$k, Comment:"PR preview signed-URL key"}')" \
  --query 'PublicKey.Id' --output text)"
KG_ID="$(aws cloudfront create-key-group --region "$REGION" \
  --key-group-config "$(jq -nc --arg id "$PK_ID" '{Name:"pr-preview-key-group", Items:[$id], Comment:"trusted signers for PR previews"}')" \
  --query 'KeyGroup.Id' --output text)"
aws secretsmanager create-secret --region "$REGION" --name "$SECRET_ID" \
  --secret-string "$(jq -nc --arg pk "$(cat "$KEY")" --arg id "$PK_ID" '{privateKey:$pk, keyPairId:$id}')" >/dev/null 2>&1 \
  || aws secretsmanager put-secret-value --region "$REGION" --secret-id "$SECRET_ID" \
       --secret-string "$(jq -nc --arg pk "$(cat "$KEY")" --arg id "$PK_ID" '{privateKey:$pk, keyPairId:$id}')" >/dev/null
log "public key $PK_ID · key group $KG_ID · private key in $SECRET_ID"

# 3. VPC origin (http-only → no origin cert needed). Wait for Deployed.
VO_ID="$(aws cloudfront create-vpc-origin --region "$REGION" \
  --vpc-origin-endpoint-config "$(jq -nc --arg arn "$INT_ARN" '{Name:"pr-preview", Arn:$arn, HTTPPort:80, HTTPSPort:443, OriginProtocolPolicy:"http-only"}')" \
  --query 'VpcOrigin.Id' --output text)"
log "VPC origin $VO_ID — waiting for Deployed (~10-15 min)…"
until [ "$(aws cloudfront get-vpc-origin --id "$VO_ID" --region "$REGION" --query 'VpcOrigin.Status' --output text)" = Deployed ]; do sleep 20; done

# 4. distribution: default behavior SIGNED (key group); /pr-*/api/health UNSIGNED for readiness.
INT_DNS="$(aws elbv2 describe-load-balancers --region "$REGION" --query "LoadBalancers[?LoadBalancerArn=='$INT_ARN']|[0].DNSName" --output text)"
DIST_CFG="$(jq -nc --arg dns "$INT_DNS" --arg vo "$VO_ID" --arg kg "$KG_ID" --arg cd "$CACHING_DISABLED" --arg av "$ALL_VIEWER" '{
  CallerReference:("pr-preview-frontdoor-"+(now|tostring)),
  Comment:"PR preview front-door — signed URLs over private ALB",
  Enabled:true,
  Origins:{Quantity:1, Items:[{Id:"preview-alb", DomainName:$dns, VpcOriginConfig:{VpcOriginId:$vo, OriginReadTimeout:30, OriginKeepaliveTimeout:5}, CustomHeaders:{Quantity:0}, OriginPath:""}]},
  DefaultCacheBehavior:{TargetOriginId:"preview-alb", ViewerProtocolPolicy:"redirect-to-https", CachePolicyId:$cd, OriginRequestPolicyId:$av, TrustedKeyGroups:{Enabled:true, Quantity:1, Items:[$kg]}, AllowedMethods:{Quantity:3, Items:["GET","HEAD","OPTIONS"], CachedMethods:{Quantity:2, Items:["GET","HEAD"]}}, Compress:true},
  CacheBehaviors:{Quantity:1, Items:[{PathPattern:"/pr-*/api/health", TargetOriginId:"preview-alb", ViewerProtocolPolicy:"redirect-to-https", CachePolicyId:$cd, OriginRequestPolicyId:$av, TrustedKeyGroups:{Enabled:false, Quantity:0}, AllowedMethods:{Quantity:3, Items:["GET","HEAD","OPTIONS"], CachedMethods:{Quantity:2, Items:["GET","HEAD"]}}, Compress:true}]},
  PriceClass:"PriceClass_100"
}')"
read -r DIST_ID DIST_DOMAIN < <(aws cloudfront create-distribution --region "$REGION" --distribution-config "$DIST_CFG" --query 'Distribution.[Id,DomainName]' --output text)
log "distribution $DIST_ID → $DIST_DOMAIN (deploying ~10-15 min)"

cat <<EOF

# Add to project.local.env:
export CF_DIST_ID=$DIST_ID
export CF_DOMAIN=$DIST_DOMAIN
export CF_SIGNING_SECRET=$SECRET_ID
export CF_KEY_GROUP=$KG_ID
export CF_VPC_ORIGIN=$VO_ID
EOF
