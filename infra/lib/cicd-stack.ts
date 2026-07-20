// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import * as cdk from 'aws-cdk-lib';
import * as ecr from 'aws-cdk-lib/aws-ecr';
import * as eks from 'aws-cdk-lib/aws-eks';
import * as iam from 'aws-cdk-lib/aws-iam';
import { NagSuppressions } from 'cdk-nag';
import { Construct } from 'constructs';

export interface CicdStackProps extends cdk.StackProps {
  githubOrg: string;
  // Repos allowed to assume the deploy role. When omitted, trust is scoped to the
  // single `githubOrg/githubRepo` (the safe default). Provide an explicit list to
  // onboard several repos without widening to the whole org.
  githubRepo?: string;
  repoAllowlist?: string[];
  // Opt-in ONLY: trust every repo in the org (`repo:org/*`). Convenient for a
  // single-owner demo org, but it means any repo (or anyone who can create one)
  // in the org can assume this role — do NOT enable it for an org with untrusted
  // members. Default false. See SECURITY.md.
  trustWholeOrg?: boolean;
  projectName: string;
  ecrRepositoryName: string;
  // Optional: the CI/CD stack does not consume the DB secret today (the deploy
  // role is scoped by tag/path, not a specific secret ARN). Kept optional so the
  // no-DB quick-start needn't stand up the DataStack. See docs/runbook.md.
  databaseSecretArn?: string;
  clusterName: string;
  // Only create an EKS access entry when CDK owns the cluster. With eksctl the
  // cluster manages its own access entries out-of-band.
  createClusterAccessEntry?: boolean;
}

/**
 * ECR + the GitHub Actions OIDC deploy role. The app repo's reusable
 * workflow assumes this role to push images and run helm against EKS. Scoped to
 * the specific repo's PR + branch refs.
 */
export class CicdStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: CicdStackProps) {
    super(scope, id, props);

    const repo = new ecr.Repository(this, 'AppRepo', {
      repositoryName: props.ecrRepositoryName,
      imageScanOnPush: true,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      // Delete pushed images on `cdk destroy` so teardown doesn't fail with
      // "repository ... cannot be deleted because it still contains images".
      emptyOnDelete: true,
      lifecycleRules: [
        { description: 'expire untagged after 7d', maxImageAge: cdk.Duration.days(7), tagStatus: ecr.TagStatus.UNTAGGED },
        { description: 'keep last 50 preview images', maxImageCount: 50, tagStatus: ecr.TagStatus.ANY },
      ],
    });

    // The GitHub OIDC provider is account-global and often already exists.
    // Reference it by ARN rather than creating a duplicate (which fails with
    // EntityAlreadyExistsException).
    const providerArn = `arn:aws:iam::${this.account}:oidc-provider/token.actions.githubusercontent.com`;
    const provider = iam.OpenIdConnectProvider.fromOpenIdConnectProviderArn(
      this,
      'GithubOidc',
      providerArn,
    );

    // Build the set of trusted `repo:...` prefixes. SAFE DEFAULT = the single
    // configured repo; widen to a caller-supplied allowlist; only trust the whole
    // org when explicitly opted in (trustWholeOrg). In every case the ref is
    // scoped to `:pull_request` runs + the `main` branch — NEVER a bare `*`
    // (which would trust arbitrary refs). Fork PRs run with a read-only token
    // that cannot assume this role regardless.
    const repoScopes: string[] = props.trustWholeOrg
      ? [`${props.githubOrg}/*`]
      : (props.repoAllowlist && props.repoAllowlist.length > 0
          ? props.repoAllowlist
          : [`${props.githubOrg}/${props.githubRepo ?? props.projectName}`]);
    const subClaims = repoScopes.flatMap((r) => [
      `repo:${r}:pull_request`,
      `repo:${r}:ref:refs/heads/main`,
    ]);

    const deployRole = new iam.Role(this, 'GithubDeployRole', {
      roleName: `${props.projectName}-github-deploy`,
      assumedBy: new iam.WebIdentityPrincipal(provider.openIdConnectProviderArn, {
        StringEquals: { 'token.actions.githubusercontent.com:aud': 'sts.amazonaws.com' },
        StringLike: {
          'token.actions.githubusercontent.com:sub': subClaims,
        },
      }),
      description: `GitHub Actions deploy role for ${props.projectName}`,
      maxSessionDuration: cdk.Duration.hours(1),
    });

    repo.grantPullPush(deployRole);
    deployRole.addToPolicy(
      new iam.PolicyStatement({
        actions: ['ecr:GetAuthorizationToken'],
        resources: ['*'], // GetAuthorizationToken cannot be resource-scoped.
      }),
    );
    deployRole.addToPolicy(
      new iam.PolicyStatement({
        actions: ['eks:DescribeCluster'],
        resources: [`arn:aws:eks:${this.region}:${this.account}:cluster/${props.clusterName}`],
      }),
    );

    // Grant the deploy role Kubernetes RBAC via an EKS Access Entry. Without
    // this, the role authenticates to the EKS API but every kubectl/helm call
    // is Unauthorized. cluster-admin is required because the workflow creates
    // arbitrary pr-<n> namespaces and installs charts into them.
    if (props.createClusterAccessEntry) {
      new eks.CfnAccessEntry(this, 'DeployRoleAccessEntry', {
        clusterName: props.clusterName,
        principalArn: deployRole.roleArn,
        type: 'STANDARD',
        accessPolicies: [
          {
            accessScope: { type: 'cluster' },
            policyArn: 'arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy',
          },
        ],
      });
    }

    // cdk-nag: the only wildcard is ecr:GetAuthorizationToken, which
    // AWS does not allow to be resource-scoped (it must be `*`). All other ECR
    // actions are scoped to this repo via grantPullPush, and eks:DescribeCluster
    // is scoped to the one cluster ARN.
    NagSuppressions.addResourceSuppressions(deployRole, [
      {
        id: 'AwsSolutions-IAM5',
        reason: 'ecr:GetAuthorizationToken requires Resource:* (AWS does not support resource-scoping it); all other actions are resource-scoped.',
        appliesTo: ['Resource::*'],
      },
    ], true);

    new cdk.CfnOutput(this, 'EcrRepositoryUri', { value: repo.repositoryUri });
    new cdk.CfnOutput(this, 'GithubDeployRoleArn', { value: deployRole.roleArn });
  }
}