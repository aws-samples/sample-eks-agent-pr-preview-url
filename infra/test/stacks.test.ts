// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import { describe, it, expect } from 'vitest';
import * as cdk from 'aws-cdk-lib';
import { Template, Match } from 'aws-cdk-lib/assertions';
import { NetworkStack } from '../lib/network-stack';
import { ClusterStack } from '../lib/cluster-stack';
import { DataStack } from '../lib/data-stack';
import { CicdStack } from '../lib/cicd-stack';

const env = { account: '000000000000', region: 'us-east-1' };

const projectName = 'pr-preview';

function synth() {
  const app = new cdk.App();
  const network = new NetworkStack(app, 'Net', { env });
  const cluster = new ClusterStack(app, 'Cluster', { env, vpc: network.vpc, clusterName: projectName, projectName });
  const data = new DataStack(app, 'Data', { env, vpc: network.vpc, projectName, clusterSecurityGroup: cluster.clusterSecurityGroup });
  const cicd = new CicdStack(app, 'Cicd', {
    env, githubOrg: 'test-org', githubRepo: projectName, projectName,
    ecrRepositoryName: `${projectName}/app`, databaseSecretArn: data.databaseSecretArn,
    clusterName: cluster.clusterName, createClusterAccessEntry: true,
  });
  return {
    network: Template.fromStack(network),
    cluster: Template.fromStack(cluster),
    data: Template.fromStack(data),
    cicd: Template.fromStack(cicd),
  };
}

describe('NetworkStack', () => {
  const { network } = synth();
  it('creates a VPC with HA NAT (3 gateways, one per AZ)', () => {
    network.resourceCountIs('AWS::EC2::VPC', 1);
    network.resourceCountIs('AWS::EC2::NatGateway', 3);
  });
});

describe('ClusterStack — EKS Auto Mode', () => {
  const { cluster } = synth();
  it('enables Auto Mode compute with the built-in node pools', () => {
    cluster.hasResourceProperties('AWS::EKS::Cluster', {
      ComputeConfig: Match.objectLike({
        Enabled: true,
        NodePools: Match.arrayWith(['general-purpose', 'system']),
      }),
    });
  });
  it('enables Ingress→ALB (elastic load balancing) and block storage', () => {
    cluster.hasResourceProperties('AWS::EKS::Cluster', {
      KubernetesNetworkConfig: Match.objectLike({ ElasticLoadBalancing: { Enabled: true } }),
      StorageConfig: Match.objectLike({ BlockStorage: { Enabled: true } }),
    });
  });
  it('pre-creates the node instance profile (the Auto Mode fix)', () => {
    cluster.resourceCountIs('AWS::IAM::InstanceProfile', 1);
    cluster.hasResourceProperties('AWS::IAM::InstanceProfile', {
      InstanceProfileName: `${projectName}-nodes`,
    });
  });
});

describe('DataStack — Aurora Serverless v2', () => {
  const { data } = synth();
  it('creates an Aurora PostgreSQL cluster with serverless v2 scaling', () => {
    data.hasResourceProperties('AWS::RDS::DBCluster', {
      Engine: 'aurora-postgresql',
      ServerlessV2ScalingConfiguration: Match.objectLike({ MinCapacity: 0.5, MaxCapacity: 4 }),
    });
  });
  it('encrypts storage', () => {
    data.hasResourceProperties('AWS::RDS::DBCluster', { StorageEncrypted: true });
  });
});

describe('CicdStack — ECR + scoped OIDC deploy role', () => {
  const { cicd } = synth();
  it('creates the ECR repo with scan-on-push', () => {
    cicd.hasResourceProperties('AWS::ECR::Repository', {
      RepositoryName: `${projectName}/app`,
      ImageScanningConfiguration: { ScanOnPush: true },
    });
  });
  it('DEFAULT: scopes OIDC trust to the SINGLE repo (not org-wide, not bare *)', () => {
    const roles = cicd.findResources('AWS::IAM::Role');
    const json = JSON.stringify(roles);
    // Safe default: only the configured org/repo is trusted...
    expect(json).toContain('repo:test-org/pr-preview:pull_request');
    expect(json).toContain('repo:test-org/pr-preview:ref:refs/heads/main');
    // ...NOT the whole org, and never a bare wildcard.
    expect(json).not.toContain('repo:test-org/*');
    expect(json).not.toMatch(/"token\.actions\.githubusercontent\.com:sub":\s*"\*"/);
    // every sub is exactly pull_request or the main ref — nothing wider.
    const subs = json.match(/repo:test-org\/[^"]+/g) ?? [];
    expect(subs.length).toBeGreaterThan(0);
    for (const s of subs) {
      expect(
        s === 'repo:test-org/pr-preview:pull_request' ||
        s === 'repo:test-org/pr-preview:ref:refs/heads/main',
      ).toBe(true);
    }
  });
  it('OPT-IN: trustWholeOrg widens to repo:org/* (still ref-scoped)', () => {
    const app = new cdk.App();
    const net = new NetworkStack(app, 'N2', { env });
    const clu = new ClusterStack(app, 'C2', { env, vpc: net.vpc, clusterName: projectName, projectName });
    const cicd2 = Template.fromStack(new CicdStack(app, 'Cicd2', {
      env, githubOrg: 'test-org', githubRepo: projectName, projectName,
      ecrRepositoryName: `${projectName}/app`, clusterName: clu.clusterName,
      trustWholeOrg: true,
    }));
    const json = JSON.stringify(cicd2.findResources('AWS::IAM::Role'));
    expect(json).toContain('repo:test-org/*:pull_request');
    expect(json).toContain('repo:test-org/*:ref:refs/heads/main');
    expect(json).not.toMatch(/"token\.actions\.githubusercontent\.com:sub":\s*"\*"/);
  });
  it('OPT-IN: repoAllowlist trusts exactly the listed repos', () => {
    const app = new cdk.App();
    const net = new NetworkStack(app, 'N3', { env });
    const clu = new ClusterStack(app, 'C3', { env, vpc: net.vpc, clusterName: projectName, projectName });
    const cicd3 = Template.fromStack(new CicdStack(app, 'Cicd3', {
      env, githubOrg: 'test-org', projectName,
      ecrRepositoryName: `${projectName}/app`, clusterName: clu.clusterName,
      repoAllowlist: ['test-org/app-a', 'test-org/app-b'],
    }));
    const json = JSON.stringify(cicd3.findResources('AWS::IAM::Role'));
    expect(json).toContain('repo:test-org/app-a:pull_request');
    expect(json).toContain('repo:test-org/app-b:ref:refs/heads/main');
    expect(json).not.toContain('repo:test-org/*');
  });
  it('creates an EKS access entry when requested', () => {
    cicd.resourceCountIs('AWS::EKS::AccessEntry', 1);
  });
});