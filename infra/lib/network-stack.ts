// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import { NagSuppressions } from 'cdk-nag';
import { Construct } from 'constructs';

/**
 * VPC for the preview platform. HA NAT (one per AZ) mirrors the eks-azi-spot
 * pattern — a single NAT is a zonal single point of failure for cluster egress.
 */
export class NetworkStack extends cdk.Stack {
  public readonly vpc: ec2.Vpc;

  constructor(scope: Construct, id: string, props: cdk.StackProps) {
    super(scope, id, props);

    this.vpc = new ec2.Vpc(this, 'Vpc', {
      ipAddresses: ec2.IpAddresses.cidr('10.20.0.0/16'),
      maxAzs: 3,
      natGateways: 3, // HA: one per AZ
      subnetConfiguration: [
        { name: 'public', subnetType: ec2.SubnetType.PUBLIC, cidrMask: 20 },
        { name: 'private', subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS, cidrMask: 19 },
      ],
    });

    // Tags the AWS Load Balancer / EKS Auto Mode use for subnet auto-discovery:
    // public subnets host the internet-facing shared ALB; private subnets carry
    // the nodes (and any internal ALB).
    for (const s of this.vpc.publicSubnets) {
      cdk.Tags.of(s).add('kubernetes.io/role/elb', '1');
    }
    for (const s of this.vpc.privateSubnets) {
      cdk.Tags.of(s).add('kubernetes.io/role/internal-elb', '1');
    }

    new cdk.CfnOutput(this, 'VpcId', { value: this.vpc.vpcId });
    // Explicit subnet-id outputs so scripts/render-eksctl-config.sh fills the
    // eksctl vpc.subnets block deterministically (no tag-filtered discovery).
    new cdk.CfnOutput(this, 'PrivateSubnetIds', {
      value: this.vpc.privateSubnets.map((s) => s.subnetId).join(','),
    });
    new cdk.CfnOutput(this, 'PublicSubnetIds', {
      value: this.vpc.publicSubnets.map((s) => s.subnetId).join(','),
    });
    new cdk.CfnOutput(this, 'AvailabilityZones', {
      value: this.vpc.availabilityZones.join(','),
    });

    // cdk-nag: VPC Flow Logs are a production observability item, not
    // needed for this reference-demo cluster. Tracked in
    // docs/roadmap-production.md.
    NagSuppressions.addResourceSuppressions(this.vpc, [
      { id: 'AwsSolutions-VPC7', reason: 'Demo cluster: VPC flow logs deferred to the production track (docs/roadmap-production.md).' },
    ]);
  }
}