// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import { describe, it, expect, beforeAll } from 'vitest';
import * as cdk from 'aws-cdk-lib';
import { Annotations, Match } from 'aws-cdk-lib/assertions';
import { AwsSolutionsChecks } from 'cdk-nag';
import { NetworkStack } from '../lib/network-stack';
import { ClusterStack } from '../lib/cluster-stack';
import { DataStack } from '../lib/data-stack';
import { CicdStack } from '../lib/cicd-stack';

// cdk-nag gate: synthesize all stacks with AwsSolutionsChecks and
// assert ZERO un-suppressed errors/warnings. This runs hermetically (no AWS
// creds) — unlike `cdk synth`, which needs creds for the VPC AZ lookup — so it
// is the CI nag gate.
const env = { account: '000000000000', region: 'us-east-1' };
const stacks: cdk.Stack[] = [];

beforeAll(() => {
  const projectName = 'pr-preview';
  const app = new cdk.App();
  const network = new NetworkStack(app, 'Net', { env });
  const cluster = new ClusterStack(app, 'Cluster', { env, vpc: network.vpc, clusterName: projectName, projectName });
  const data = new DataStack(app, 'Data', { env, vpc: network.vpc, projectName, clusterSecurityGroup: cluster.clusterSecurityGroup });
  const cicd = new CicdStack(app, 'Cicd', {
    env, githubOrg: 'test-org', projectName, ecrRepositoryName: `${projectName}/app`,
    databaseSecretArn: data.databaseSecretArn, clusterName: cluster.clusterName,
    createClusterAccessEntry: true,
  });
  cdk.Aspects.of(app).add(new AwsSolutionsChecks({ verbose: true }));
  app.synth({ force: true });
  // Include the ClusterStack: the AwsSolutions rules (EKS1/EKS2/IAM4/IAM5) DO
  // fire on the L1 CfnCluster, so it must be in the gate (caught by code-review).
  stacks.push(network, cluster, data, cicd);
});

describe('cdk-nag — no un-suppressed findings', () => {
  for (const name of ['Net', 'Cluster', 'Data', 'Cicd']) {
    it(`${name} has no AwsSolutions errors`, () => {
      const stack = stacks.find((s) => s.stackName === name)!;
      const errors = Annotations.fromStack(stack).findError('*', Match.stringLikeRegexp('AwsSolutions-.*'));
      expect(errors).toHaveLength(0);
    });
    it(`${name} has no nag warnings`, () => {
      const stack = stacks.find((s) => s.stackName === name)!;
      const warnings = Annotations.fromStack(stack).findWarning('*', Match.stringLikeRegexp('AwsSolutions-.*|CdkNagValidationFailure'));
      expect(warnings).toHaveLength(0);
    });
  }
});