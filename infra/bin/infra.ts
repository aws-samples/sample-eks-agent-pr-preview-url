#!/usr/bin/env node
// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import * as cdk from 'aws-cdk-lib';
import { AwsSolutionsChecks } from 'cdk-nag';
import { NetworkStack } from '../lib/network-stack';
import { ClusterStack } from '../lib/cluster-stack';
import { DataStack } from '../lib/data-stack';
import { CicdStack } from '../lib/cicd-stack';

const app = new cdk.App();

const env = {
  account: process.env.CDK_DEFAULT_ACCOUNT,
  region: process.env.CDK_DEFAULT_REGION ?? 'us-east-1',
};

// One knob names every resource (override via `-c projectName=...` or PROJECT_NAME).
// Keep it short: it seeds an IAM role name (64-char cap). Lowercase/digits/hyphens.
const projectName =
  app.node.tryGetContext('projectName') ?? process.env.PROJECT_NAME ?? 'pr-preview';

// GitHub org allowed to assume the deploy role (override via context or env).
const githubOrg =
  app.node.tryGetContext('githubOrg') ?? process.env.GITHUB_ORG ?? 'your-org';
const githubRepo = app.node.tryGetContext('githubRepo') ?? projectName;
// OIDC trust scope. Default: trust only `githubOrg/githubRepo`. Widen with a
// comma-separated `repoAllowlist` (e.g. `-c repoAllowlist=org/a,org/b`), or opt
// into whole-org trust with `-c trustWholeOrg=true` (see SECURITY.md).
const repoAllowlistRaw = app.node.tryGetContext('repoAllowlist') ?? process.env.REPO_ALLOWLIST;
const repoAllowlist = repoAllowlistRaw
  ? String(repoAllowlistRaw).split(',').map((s) => s.trim()).filter(Boolean)
  : undefined;
const trustWholeOrg =
  (app.node.tryGetContext('trustWholeOrg') ?? process.env.TRUST_WHOLE_ORG) === true ||
  (app.node.tryGetContext('trustWholeOrg') ?? process.env.TRUST_WHOLE_ORG) === 'true';
// Cluster provisioner: 'eksctl' (recommended — Auto Mode node role works) or
// 'cdk' (opt-in; see infra/lib/cluster-stack.ts and docs/runbook.md). Default eksctl.
const clusterProvisioner = app.node.tryGetContext('clusterProvisioner') ?? 'eksctl';
const clusterName = projectName;

// Stable, human-readable stack ids derived from the project name. The CICD stack
// id is read back by scripts/onboard-app.sh, so keep them in sync via projectName.
const stackId = (suffix: string) =>
  projectName
    .split(/[^a-zA-Z0-9]+/)
    .filter(Boolean)
    .map((w: string) => w.charAt(0).toUpperCase() + w.slice(1))
    .join('') + suffix;

const tags = { project: projectName, 'managed-by': 'cdk' };

const network = new NetworkStack(app, stackId('Network'), { env, tags });

// Only create the CDK cluster stack when explicitly requested; with eksctl the
// cluster is provisioned out-of-band and CDK manages VPC / Aurora / ECR / OIDC.
let cluster: ClusterStack | undefined;
if (clusterProvisioner === 'cdk') {
  cluster = new ClusterStack(app, stackId('Cluster'), {
    env,
    tags,
    vpc: network.vpc,
    clusterName,
    projectName,
  });
}

const data = new DataStack(app, stackId('Data'), {
  env,
  tags,
  vpc: network.vpc,
  clusterSecurityGroup: cluster?.clusterSecurityGroup,
  projectName,
});

const cicd = new CicdStack(app, stackId('Cicd'), {
  env,
  tags,
  githubOrg,
  githubRepo,
  repoAllowlist,
  trustWholeOrg,
  projectName,
  ecrRepositoryName: `${projectName}/app`,
  databaseSecretArn: data.databaseSecretArn,
  clusterName,
  // eksctl manages its own cluster access; only CDK creates the access entry.
  createClusterAccessEntry: clusterProvisioner === 'cdk',
});
if (cluster) cicd.addDependency(cluster);

// cdk-nag: AWS Solutions checks across all stacks. Intentional
// trade-offs are suppressed with written justifications in each stack
// (NagSuppressions). CI fails on any UN-suppressed finding.
cdk.Aspects.of(app).add(new AwsSolutionsChecks({ verbose: true }));

app.synth();
