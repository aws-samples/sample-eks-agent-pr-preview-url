// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as rds from 'aws-cdk-lib/aws-rds';
import { NagSuppressions } from 'cdk-nag';
import { Construct } from 'constructs';

export interface DataStackProps extends cdk.StackProps {
  vpc: ec2.IVpc;
  projectName: string;
  // Optional: when the cluster is CDK-managed, peer its SG explicitly. With an
  // eksctl-managed cluster the in-VPC CIDR rule already covers the nodes.
  clusterSecurityGroup?: ec2.ISecurityGroup;
}

/**
 * Shared sandbox backend: ONE Aurora Serverless v2 (PostgreSQL)
 * cluster that all Preview Environments share with Preview-scoped credentials.
 * Compute-isolated, data-shared. Part of the long-lived baseline — not torn down
 * per PR. Aurora Serverless v2 has an ACU floor (no scale-to-zero).
 *
 * The connection secret is synced into each pr-<n> namespace by ESO at runtime,
 * so credentials never live in git.
 */
export class DataStack extends cdk.Stack {
  public readonly databaseSecretArn: string;

  constructor(scope: Construct, id: string, props: DataStackProps) {
    super(scope, id, props);

    const dbSg = new ec2.SecurityGroup(this, 'AuroraSg', {
      vpc: props.vpc,
      // ASCII only — EC2 rejects non-ASCII in GroupDescription.
      description: 'Aurora preview sandbox - in-VPC ingress only',
      allowAllOutbound: false,
    });
    // Allow Postgres from anywhere inside the VPC. We intentionally do NOT scope
    // to the cluster control-plane SG: EKS Auto Mode launches preview pods behind
    // an Auto-Mode-managed node SG that is distinct from the cluster SG, so a
    // cluster-SG-only rule would silently drop pod→Aurora traffic. The VPC is
    // private (pods are in PRIVATE_WITH_EGRESS subnets), so VPC-CIDR scope is the
    // correct, reliable boundary for the shared sandbox. The clusterSecurityGroup
    // is also peered explicitly for control-plane-initiated checks.
    dbSg.addIngressRule(
      ec2.Peer.ipv4(props.vpc.vpcCidrBlock),
      ec2.Port.tcp(5432),
      'Postgres from inside the VPC (Auto Mode pods)',
    );
    if (props.clusterSecurityGroup) {
      dbSg.addIngressRule(
        ec2.Peer.securityGroupId(props.clusterSecurityGroup.securityGroupId),
        ec2.Port.tcp(5432),
        'Postgres from the EKS cluster SG',
      );
    }

    const cluster = new rds.DatabaseCluster(this, 'Aurora', {
      engine: rds.DatabaseClusterEngine.auroraPostgres({
        version: rds.AuroraPostgresEngineVersion.VER_16_4,
      }),
      vpc: props.vpc,
      vpcSubnets: { subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS },
      securityGroups: [dbSg],
      // Serverless v2 capacity range — scales down when previews are idle.
      serverlessV2MinCapacity: 0.5,
      serverlessV2MaxCapacity: 4,
      writer: rds.ClusterInstance.serverlessV2('writer'),
      defaultDatabaseName: 'preview',
      // Credentials auto-generated into Secrets Manager → ESO syncs from here.
      credentials: rds.Credentials.fromGeneratedSecret('preview_app', {
        secretName: `${props.projectName}/preview/database`,
      }),
      removalPolicy: cdk.RemovalPolicy.DESTROY, // demo: tear down with the stack
      storageEncrypted: true,
      // Allow IAM-based DB auth in addition to the generated password, so callers
      // can move off the shared static credential toward per-principal IAM tokens
      // (CKV_AWS_162; see SECURITY.md — the shared DB user is a single trust domain).
      iamAuthentication: true,
    });

    this.databaseSecretArn = cluster.secret!.secretArn;

    // cdk-nag: shared sandbox DB for ephemeral previews.
    NagSuppressions.addResourceSuppressions(cluster, [
      { id: 'AwsSolutions-RDS10', reason: 'Demo: removalPolicy is DESTROY by design (preview sandbox tears down with the stack); deletion protection would block that.' },
      { id: 'AwsSolutions-RDS6', reason: 'Previews authenticate with a Preview-scoped password synced via ESO; IAM DB auth is a production-track item.' },
      { id: 'AwsSolutions-SMG4', reason: 'Sandbox credential; automatic rotation deferred to the production track (docs/roadmap-production.md).' },
    ], true); // applyToChildren → covers the generated Aurora/Secret resource
    // EC23 cannot evaluate the SG rule because the source is the VPC CIDR (an
    // intrinsic Fn::GetAtt), not a literal — it is a deliberate in-VPC-only rule,
    // so suppress the validation-failure.
    NagSuppressions.addResourceSuppressions(dbSg, [
      { id: 'CdkNagValidationFailure', reason: 'EC23 cannot resolve the VPC-CIDR intrinsic; the rule is intentional in-VPC-only Postgres ingress.' },
    ], true);

    new cdk.CfnOutput(this, 'DatabaseSecretArn', { value: this.databaseSecretArn });
    new cdk.CfnOutput(this, 'DatabaseEndpoint', { value: cluster.clusterEndpoint.hostname });
  }
}