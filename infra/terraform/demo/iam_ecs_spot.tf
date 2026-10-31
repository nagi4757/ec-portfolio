# Phase 6C-3: the instance role for ECS EC2 Spot hosts.
#
# Held apart from aws_iam_role.ec2 rather than extended onto it. Adding ECS
# registration to the On-Demand origin host's role would give the host that is
# currently serving production the ability to join the cluster, which it has no
# reason to do and which would be one more thing that could go wrong during the
# Phase 6C-5 cutover. Separate roles also mean the Spot side can be removed, or
# the On-Demand side retired, without editing the other.
#
# The AWS-managed AmazonEC2ContainerServiceforEC2Role is deliberately not
# attached. It grants fifteen actions on "*", including ecs:CreateCluster and
# CloudWatch Logs writes this host does not need, and it cannot be scoped to
# one cluster. The statements below cover the same agent contract with the
# cluster and repository named.

resource "aws_iam_role" "ecs_spot" {
  name        = local.ecs_spot_name
  description = "Demo ECS EC2 Spot host role: container instance registration, runtime bundle read, and origin TLS state"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = local.ecs_spot_name
  }
}

resource "aws_iam_instance_profile" "ecs_spot" {
  name = local.ecs_spot_name
  role = aws_iam_role.ecs_spot.name

  tags = {
    Name = local.ecs_spot_name
  }
}

resource "aws_iam_role_policy" "ecs_spot_session_manager" {
  name = "session-manager-core"
  role = aws_iam_role.ecs_spot.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # The instance ID is not known until the Auto Scaling group creates it,
        # so there is no ARN to name here. This matches the On-Demand host's
        # policy rather than inventing a different shape for the same need.
        Sid      = "RegisterManagedInstance"
        Effect   = "Allow"
        Action   = "ssm:UpdateInstanceInformation"
        Resource = "*"
      },
      {
        Sid    = "OpenSessionManagerChannels"
        Effect = "Allow"
        Action = [
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel",
        ]
        Resource = "*"
      },
    ]
  })
}

# The ECS container agent's own contract, and nothing beyond it.
#
# ecs:CreateCluster is omitted: the cluster is a Terraform resource, and an
# agent that could create one could also register somewhere this deployment
# does not own. ecs:TagResource and ecs:ListTagsForResource are omitted too --
# the agent only calls TagResource when it registers with tags, which requires
# ECS_CONTAINER_INSTANCE_TAGS or ECS_CONTAINER_INSTANCE_PROPAGATE_TAGS_FROM,
# and bootstrap-spot-host.sh sets neither; ListTagsForResource is used only by
# the task metadata endpoint's /taskWithTags path, which nothing here calls.
# ec2:DescribeTags is omitted for the same reason: the agent reads EC2 tags
# only when propagation is turned on. The capacity provider association is
# decided by ECS from the AmazonECSManaged tag on the instance, server side.
resource "aws_iam_role_policy" "ecs_spot_container_instance" {
  name = "ecs-container-instance"
  role = aws_iam_role.ecs_spot.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "RegisterWithDemoCluster"
        Effect = "Allow"
        Action = [
          "ecs:RegisterContainerInstance",
          "ecs:DeregisterContainerInstance",
          "ecs:SubmitAttachmentStateChanges",
          "ecs:SubmitContainerStateChange",
          "ecs:SubmitTaskStateChange",
        ]
        Resource = aws_ecs_cluster.demo.arn
      },
      {
        # These act on the container instance, not the cluster, and the
        # container instance ARN embeds the cluster name -- so naming the
        # cluster in the path already confines them to this cluster. An
        # ecs:cluster condition on top would add nothing and one more way for
        # registration to fail.
        Sid    = "PollAndDrainThisClustersInstances"
        Effect = "Allow"
        Action = [
          "ecs:Poll",
          "ecs:StartTelemetrySession",
          "ecs:UpdateContainerInstancesState",
        ]
        Resource = "arn:${data.aws_partition.current.partition}:ecs:${local.aws_region}:${data.aws_caller_identity.current.account_id}:container-instance/${local.ecs_cluster_name}/*"
      },
      {
        # The only ECS action in this role with no resource type at all, so "*"
        # is the sole form the service accepts.
        Sid      = "DiscoverAgentPollEndpoint"
        Effect   = "Allow"
        Action   = "ecs:DiscoverPollEndpoint"
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_role_policy" "ecs_spot_ecr_pull" {
  name = "ecr-image-pull"
  role = aws_iam_role.ecs_spot.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "GetEcrAuthorizationToken"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "PullDemoApiImage"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
        ]
        Resource = aws_ecr_repository.demo_api.arn
      },
    ]
  })
}

# Read-only, and version-addressed. s3:GetObject is absent as well as
# s3:ListBucket: the loader always supplies a version ID, and S3 requires
# s3:GetObjectVersion rather than s3:GetObject for that request. Granting
# s3:GetObject would add the ability to fetch whatever is current at the key,
# which is exactly the mutable read this design exists to avoid.
resource "aws_iam_role_policy" "ecs_spot_runtime_bundle" {
  name = "runtime-bundle-read"
  role = aws_iam_role.ecs_spot.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadPinnedRuntimeBundleVersion"
        Effect   = "Allow"
        Action   = "s3:GetObjectVersion"
        Resource = "${aws_s3_bucket.runtime_artifacts.arn}/${local.spot_runtime_object_key}"
      },
    ]
  })
}

# The same two actions on the same single object the On-Demand host holds.
# s3:ListBucket is absent because the key is fixed, and s3:DeleteObject is
# absent so a host can replace the archive but never destroy the history an
# operator would recover from.
resource "aws_iam_role_policy" "ecs_spot_origin_tls_backup" {
  name = "origin-tls-backup"
  role = aws_iam_role.ecs_spot.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadWriteOriginTlsArchive"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
        ]
        Resource = "${aws_s3_bucket.origin_tls.arn}/origin-tls/letsencrypt.tar.gz"
      },
    ]
  })
}

resource "aws_iam_role_policy" "ecs_spot_origin_verification" {
  name = "origin-verification-read"
  role = aws_iam_role.ecs_spot.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadOriginVerificationToken"
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = aws_ssm_parameter.origin_verify_token.arn
      },
    ]
  })
}

# Renewal reaches ACME through DNS-01, so the host has to write one TXT record
# and nothing else. The conditions pin the action set, the exact record name
# and the record type, so this grant cannot be turned into control of the zone.
resource "aws_iam_role_policy" "ecs_spot_acme_dns_route53" {
  name = "acme-dns-route53"
  role = aws_iam_role.ecs_spot.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DiscoverHostedZones"
        Effect   = "Allow"
        Action   = "route53:ListHostedZones"
        Resource = "*"
      },
      {
        Sid      = "PollDnsChange"
        Effect   = "Allow"
        Action   = "route53:GetChange"
        Resource = "arn:${data.aws_partition.current.partition}:route53:::change/*"
      },
      {
        Sid      = "ManageExactAcmeChallenge"
        Effect   = "Allow"
        Action   = "route53:ChangeResourceRecordSets"
        Resource = "arn:${data.aws_partition.current.partition}:route53:::hostedzone/${data.aws_route53_zone.demo_public.zone_id}"
        Condition = {
          "ForAllValues:StringEquals" = {
            "route53:ChangeResourceRecordSetsActions"               = ["UPSERT", "DELETE"]
            "route53:ChangeResourceRecordSetsNormalizedRecordNames" = [local.origin_acme_challenge_record]
            "route53:ChangeResourceRecordSetsRecordTypes"           = ["TXT"]
          }
        }
      },
    ]
  })
}

# CompleteLifecycleAction carries both outcomes, so CONTINUE and ABANDON need
# no separate grant. RecordLifecycleActionHeartbeat is not granted: the hook's
# heartbeat timeout is sized to outlast the whole bootstrap, so nothing has to
# extend it, and a host that could extend its own wait could also sit in
# Pending:Wait indefinitely.
resource "aws_iam_role_policy" "ecs_spot_lifecycle_completion" {
  name = "launch-lifecycle-completion"
  role = aws_iam_role.ecs_spot.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "CompleteOwnLaunchLifecycleAction"
        Effect   = "Allow"
        Action   = "autoscaling:CompleteLifecycleAction"
        Resource = aws_autoscaling_group.ecs_spot.arn
      },
    ]
  })
}
