// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as eks from 'aws-cdk-lib/aws-eks';
import * as iam from 'aws-cdk-lib/aws-iam';
import { NagSuppressions } from 'cdk-nag';
import { Construct } from 'constructs';

export interface ClusterStackProps extends cdk.StackProps {
  vpc: ec2.IVpc;
  clusterName: string;
  projectName: string;
}

/**
 * EKS Auto Mode cluster, expressed with the L1 CfnCluster.
 *
 * Auto Mode (computeConfig.enabled + the built-in system/general-purpose
 * nodePools) manages compute, and elasticLoadBalancing.enabled lets the cluster
 * provision ALBs directly from Ingress — the substrate the shared-ALB preview
 * routing depends on. Using the L1 construct keeps Auto Mode explicit and avoids
 * the L2's nodegroup + kubectl-layer machinery that Auto Mode makes unnecessary.
 */
export class ClusterStack extends cdk.Stack {
  public readonly cluster: eks.CfnCluster;
  public readonly clusterSecurityGroup: ec2.ISecurityGroup;
  public readonly clusterName: string;
  public readonly nodeInstanceProfileName!: string;

  constructor(scope: Construct, id: string, props: ClusterStackProps) {
    super(scope, id, props);
    this.clusterName = props.clusterName;

    // Cluster IAM role (control plane).
    const clusterRole = new iam.Role(this, 'ClusterRole', {
      assumedBy: new iam.ServicePrincipal('eks.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonEKSClusterPolicy'),
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonEKSComputePolicy'),
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonEKSBlockStoragePolicy'),
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonEKSLoadBalancingPolicy'),
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonEKSNetworkingPolicy'),
      ],
    });
    // AmazonEKSComputePolicy grants AddRoleToInstanceProfile but NOT
    // CreateInstanceProfile/TagInstanceProfile. With a CUSTOM node role, Auto
    // Mode must create+tag the `eks-*` instance profile itself; without these
    // it leaves an empty profile shell and NodeClass stays InstanceProfileReady
    // =False forever (no nodes ever provision). Grant them, scoped to eks*.
    clusterRole.addToPolicy(
      new iam.PolicyStatement({
        actions: [
          'iam:CreateInstanceProfile',
          'iam:TagInstanceProfile',
          'iam:GetInstanceProfile',
          'iam:AddRoleToInstanceProfile',
          'iam:RemoveRoleFromInstanceProfile',
          'iam:DeleteInstanceProfile',
        ],
        resources: [`arn:aws:iam::${cdk.Aws.ACCOUNT_ID}:instance-profile/eks*`],
      }),
    );

    // Node IAM role used by Auto Mode managed instances.
    const nodeRole = new iam.Role(this, 'NodeRole', {
      assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonEKSWorkerNodeMinimalPolicy'),
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonEC2ContainerRegistryPullOnly'),
      ],
    });

    // Auto Mode passes the node role to EC2 when launching managed nodes; the
    // cluster role needs PassRole on it for the instance profile to be usable.
    clusterRole.addToPolicy(
      new iam.PolicyStatement({
        actions: ['iam:PassRole'],
        resources: [nodeRole.roleArn],
        conditions: { StringEquals: { 'iam:PassedToService': 'ec2.amazonaws.com' } },
      }),
    );

    // Pre-create the node instance profile (with the node role attached) rather
    // than letting Auto Mode auto-create it. With a CUSTOM node role + the L1
    // CfnCluster, Auto Mode's auto-creation leaves the profile role-less and the
    // NodeClass stuck at InstanceProfileReady=False. The Auto Mode NodeClass must
    // then reference this via its `instanceProfile` field (not `role`).
    // See docs/eks-results.md.
    const nodeInstanceProfile = new iam.CfnInstanceProfile(this, 'NodeInstanceProfile', {
      instanceProfileName: `${props.projectName}-nodes`,
      roles: [nodeRole.roleName],
    });
    this.nodeInstanceProfileName = nodeInstanceProfile.ref;

    const sg = new ec2.SecurityGroup(this, 'ClusterSg', {
      vpc: props.vpc,
      description: 'EKS preview cluster security group',
      allowAllOutbound: true,
    });
    this.clusterSecurityGroup = sg;

    const privateSubnetIds = props.vpc.selectSubnets({
      subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS,
    }).subnetIds;

    this.cluster = new eks.CfnCluster(this, 'Cluster', {
      name: this.clusterName,
      version: '1.31',
      roleArn: clusterRole.roleArn,
      resourcesVpcConfig: {
        subnetIds: privateSubnetIds,
        securityGroupIds: [sg.securityGroupId],
        endpointPublicAccess: true,
        endpointPrivateAccess: true,
      },
      accessConfig: {
        authenticationMode: 'API_AND_CONFIG_MAP',
        // The principal that runs `cdk deploy` becomes a cluster admin, so
        // kubectl/helm work out of the box for the operator. The CI deploy role
        // gets its own access entry in CicdStack.
        bootstrapClusterCreatorAdminPermissions: true,
      },
      // --- EKS Auto Mode ---
      computeConfig: {
        enabled: true,
        nodePools: ['general-purpose', 'system'],
        nodeRoleArn: nodeRole.roleArn,
      },
      kubernetesNetworkConfig: {
        elasticLoadBalancing: { enabled: true }, // Ingress → ALB
      },
      storageConfig: {
        blockStorage: { enabled: true },
      },
      logging: {
        clusterLogging: {
          // All 5 control-plane log types (satisfies cdk-nag AwsSolutions-EKS2).
          enabledTypes: [
            { type: 'api' }, { type: 'audit' }, { type: 'authenticator' },
            { type: 'controllerManager' }, { type: 'scheduler' },
          ],
        },
      },
    });

    // cdk-nag: suppress the cluster's intentional trade-offs so the
    // app-wide AwsSolutionsChecks aspect passes on the `clusterProvisioner=cdk`
    // path. EKS2 is satisfied above (all 5 logs), so only these remain.
    NagSuppressions.addResourceSuppressions(this, [
      {
        id: 'AwsSolutions-EKS1',
        reason: 'Public API endpoint kept for the demo (operators + GitHub Actions reach the cluster); private-only endpoint is a production-track item (docs/roadmap-production.md). Access is still IAM + RBAC gated.',
      },
      {
        id: 'AwsSolutions-IAM4',
        reason: 'EKS Auto Mode cluster/node roles require the AWS-managed EKS policies (AmazonEKSClusterPolicy, *ComputePolicy, *BlockStoragePolicy, *LoadBalancingPolicy, *NetworkingPolicy, *WorkerNodeMinimalPolicy, ECR pull). These are the documented Auto Mode policies; replacing them with customer-managed copies adds no security and risks drift.',
        appliesTo: [
          'Policy::arn:<AWS::Partition>:iam::aws:policy/AmazonEKSClusterPolicy',
          'Policy::arn:<AWS::Partition>:iam::aws:policy/AmazonEKSComputePolicy',
          'Policy::arn:<AWS::Partition>:iam::aws:policy/AmazonEKSBlockStoragePolicy',
          'Policy::arn:<AWS::Partition>:iam::aws:policy/AmazonEKSLoadBalancingPolicy',
          'Policy::arn:<AWS::Partition>:iam::aws:policy/AmazonEKSNetworkingPolicy',
          'Policy::arn:<AWS::Partition>:iam::aws:policy/AmazonEKSWorkerNodeMinimalPolicy',
          'Policy::arn:<AWS::Partition>:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly',
        ],
      },
      {
        id: 'AwsSolutions-IAM5',
        reason: 'The cluster role must create/manage the Auto Mode node instance profile, scoped to eks* instance profiles; narrower scoping is not possible since Auto Mode names the profile.',
        appliesTo: ['Resource::arn:aws:iam::<AWS::AccountId>:instance-profile/eks*'],
      },
    ], true);

    new cdk.CfnOutput(this, 'ClusterName', { value: this.cluster.name! });
    new cdk.CfnOutput(this, 'KubectlCommand', {
      value: `aws eks update-kubeconfig --name ${this.clusterName} --region ${this.region}`,
    });
  }
}