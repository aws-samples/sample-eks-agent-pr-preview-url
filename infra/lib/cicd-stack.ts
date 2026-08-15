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
  // ESCAPE HATCH — normally unnecessary. By default the trust already covers BOTH
  // the legacy (`repo:org/repo:<ref>`) and the post-2026-07-15 immutable
  // (`repo:org@<orgId>/repo@<repoId>:<ref>`) subject formats, so new and old repos
  // both work without configuration. Set this only to pin exact claims, e.g.
  //   ["repo:user@123/repo@456:*"]
  // (copy from: repo Settings → Actions → OpenID Connect). When provided it
  // REPLACES the generated claims entirely.
  oidcSubClaims?: string[];
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

    // Build the set of trusted `repo:...` sub claims.
    //
    // GitHub has TWO subject formats, and which one a token carries depends on
    // when the *app* repo was created:
    //   legacy    : repo:<owner>/<repo>:<ref>
    //   immutable : repo:<owner>@<ownerId>/<repo>@<repoId>:<ref>   (delimiter '@')
    // Repos created (or renamed/transferred) after 2026-07-15 present the
    // immutable form; older repos keep the legacy form until they opt in.
    // See: github.blog/changelog/2026-04-23-immutable-subject-claims-for-github-actions-oidc-tokens
    //
    // We emit BOTH forms so the deploy role works regardless of the app repo's
    // age. A legacy-only trust silently fails `AssumeRoleWithWebIdentity` with
    // "Not authorized" for any post-cutoff repo, even though the org/repo names
    // look correct — a confusing failure this avoids by default.
    //
    // The immutable pattern keeps the owner/repo NAMES pinned and wildcards only
    // the numeric ids GitHub appends: '@' can never appear in a GitHub owner or
    // repo name, so `<owner>@*` matches only "<owner> followed by its id" — never
    // a different owner. Refs stay scoped to PRs + main; never a bare `*`.
    let subClaims: string[];
    if (props.oidcSubClaims && props.oidcSubClaims.length > 0) {
      // Explicit override: exact claims supplied by the operator (e.g. copied from
      // repo Settings → Actions → OpenID Connect). Used verbatim.
      subClaims = props.oidcSubClaims;
    } else {
      const repoScopes: string[] = props.trustWholeOrg
        ? [`${props.githubOrg}/*`]
        : (props.repoAllowlist && props.repoAllowlist.length > 0
            ? props.repoAllowlist
            : [`${props.githubOrg}/${props.githubRepo ?? props.projectName}`]);
      // Immutable equivalent of a scope. `owner/*` needs no repo-id wildcard —
      // the trailing `*` already spans the whole `<repo>@<repoId>` segment.
      const immutableScope = (r: string): string => {
        const slash = r.indexOf('/');
        const owner = r.slice(0, slash);
        const repo = r.slice(slash + 1);
        return repo === '*' ? `${owner}@*/*` : `${owner}@*/${repo}@*`;
      };
      const refs = ['pull_request', 'ref:refs/heads/main'];
      subClaims = repoScopes.flatMap((r) =>
        [r, immutableScope(r)].flatMap((scope) => refs.map((ref) => `repo:${scope}:${ref}`)),
      );
    }

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