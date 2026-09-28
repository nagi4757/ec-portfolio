# Phase 6C-3 adds the ECS on EC2 Spot foundation to the Demo root: an ECS
# cluster and capacity provider, a Spot launch template and Auto Scaling group
# with a launch lifecycle hook, the host IAM role and instance profile, and the
# runtime artifacts bucket with its bundle object. These are the reads the
# post-apply convergence plan makes on them.
#
# The action set was derived from the refresh calls of AWS provider 6.62
# (resource Read functions and the tag interceptor), mapped to IAM actions
# through the AWS service reference. It is not a guess from resource names:
#   - Every ECS action has a resource type, so both are granted on the exact
#     cluster and capacity provider ARNs.
#   - autoscaling:DescribeAutoScalingGroups and DescribeLifecycleHooks have no
#     resource type in the service reference, so they can only take "*".
#   - Launch template reads (ec2:Describe*), iam:GetRole, iam:GetRolePolicy and
#     iam:GetInstanceProfile are already allowed by the existing statements.
#   - The cluster, capacity provider, role and instance profile reads return
#     their tags, so no ListTagsForResource / ListRoleTags is needed.
#   - s3:GetBucketTagging instead of s3:ListTagsForResource, for the reason
#     given in policy_plan_origin_tls.tf.
#   - The object reads are HeadObject (s3:GetObject) without a version ID and
#     GetObjectTagging. No object version is read.
#
# The bucket is created with bucket_prefix, so its name, and therefore its ARN,
# is only known after the apply. The pattern is limited to that prefix; the
# object statement is limited to the one bundle key.
data "aws_iam_policy_document" "plan_spot_foundation" {
  statement {
    sid    = "ReadSpotFoundationEcsCluster"
    effect = "Allow"
    actions = [
      "ecs:DescribeClusters",
    ]
    resources = [
      "arn:aws:ecs:ap-northeast-1:${local.account_id}:cluster/ec-portfolio-demo",
    ]
  }

  statement {
    sid    = "ReadSpotFoundationEcsCapacityProvider"
    effect = "Allow"
    actions = [
      "ecs:DescribeCapacityProviders",
    ]
    resources = [
      "arn:aws:ecs:ap-northeast-1:${local.account_id}:capacity-provider/ec-portfolio-demo-ecs-spot",
    ]
  }

  statement {
    sid    = "ReadSpotFoundationAutoScaling"
    effect = "Allow"
    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeLifecycleHooks",
    ]
    resources = [
      "*",
    ]
  }

  statement {
    sid    = "ReadEcsSpotRolePolicyLists"
    effect = "Allow"
    actions = [
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
    ]
    resources = [
      "arn:aws:iam::${local.account_id}:role/ec-portfolio-demo-ecs-spot",
    ]
  }

  statement {
    sid    = "ReadRuntimeArtifactsBucket"
    effect = "Allow"
    actions = [
      "s3:GetAccelerateConfiguration",
      "s3:GetBucketAcl",
      "s3:GetBucketCORS",
      "s3:GetBucketLogging",
      "s3:GetBucketObjectLockConfiguration",
      "s3:GetBucketOwnershipControls",
      "s3:GetBucketPolicy",
      "s3:GetBucketPublicAccessBlock",
      "s3:GetBucketRequestPayment",
      "s3:GetBucketTagging",
      "s3:GetBucketVersioning",
      "s3:GetBucketWebsite",
      "s3:GetEncryptionConfiguration",
      "s3:GetLifecycleConfiguration",
      "s3:GetReplicationConfiguration",
      "s3:ListBucket",
    ]
    resources = [
      "arn:aws:s3:::ec-portfolio-demo-runtime-artifacts-*",
    ]
  }

  statement {
    sid    = "ReadSpotRuntimeBundleObject"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectTagging",
    ]
    resources = [
      "arn:aws:s3:::ec-portfolio-demo-runtime-artifacts-*/runtime/spot-runtime.tar.gz",
    ]
  }
}
