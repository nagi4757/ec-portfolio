# Phase 6C-5c: the roles of the separate measurement stack (ecs_measurement.tf).
#
# Each role carries one inline policy, the document reviewed in the Access IaC
# README (Measurement runtime roles). Every ARN below is built from fixed names
# rather than read from the resources it names, so the whole document is known
# in the plan that creates the stack and can be compared with the reviewed one
# before apply. The measurement plan gate does that comparison.
#
# Neither role is a production role, and neither names a production resource
# it could change: the host role registers with the measurement cluster only and
# completes lifecycle actions of the measurement group only, and the task
# execution role writes to the measurement log group only. What they read --
# the image, the runtime bundle version, the origin TLS archive and three
# parameters -- is what the production roles read.

locals {
  measurement_arn_prefix = "arn:${data.aws_partition.current.partition}"
  measurement_account_id = data.aws_caller_identity.current.account_id

  measurement_cluster_arn = "${local.measurement_arn_prefix}:ecs:${local.aws_region}:${local.measurement_account_id}:cluster/${local.measurement_cluster_name}"

  # The group ID exists only once the group does; the name is fixed.
  measurement_group_arn = "${local.measurement_arn_prefix}:autoscaling:${local.aws_region}:${local.measurement_account_id}:autoScalingGroup:*:autoScalingGroupName/${local.measurement_name}"

  measurement_log_group_arn = "${local.measurement_arn_prefix}:logs:${local.aws_region}:${local.measurement_account_id}:log-group:${local.measurement_log_group_name}"
}

resource "aws_iam_role" "ecs_spot_measurement" {
  count = local.measurement_count

  name        = local.measurement_name
  description = "Demo measurement ECS EC2 Spot host role: measurement cluster registration and the production runtime reads"

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
    Name = local.measurement_name
  }
}

resource "aws_iam_instance_profile" "ecs_spot_measurement" {
  count = local.measurement_count

  name = local.measurement_name
  role = aws_iam_role.ecs_spot_measurement[0].name

  tags = {
    Name = local.measurement_name
  }
}

# The production Spot role's agent, image pull, bundle, verification token and
# lifecycle statements (iam_ecs_spot.tf) with the cluster, its container
# instances and the group replaced. The origin TLS archive is read only, so a
# measurement host can never write a certificate back. Absent on purpose:
# acme-dns-route53 and session-manager-core.
resource "aws_iam_role_policy" "ecs_spot_measurement" {
  count = local.measurement_count

  name = "measurement-host"
  role = aws_iam_role.ecs_spot_measurement[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "RegisterWithMeasurementClusterOnly"
        Effect = "Allow"
        Action = [
          "ecs:RegisterContainerInstance",
          "ecs:DeregisterContainerInstance",
          "ecs:SubmitAttachmentStateChanges",
          "ecs:SubmitContainerStateChange",
          "ecs:SubmitTaskStateChange",
        ]
        Resource = local.measurement_cluster_arn
      },
      {
        Sid    = "PollAndDrainMeasurementClusterInstances"
        Effect = "Allow"
        Action = [
          "ecs:Poll",
          "ecs:StartTelemetrySession",
          "ecs:UpdateContainerInstancesState",
        ]
        Resource = "${local.measurement_arn_prefix}:ecs:${local.aws_region}:${local.measurement_account_id}:container-instance/${local.measurement_cluster_name}/*"
      },
      {
        Sid      = "DiscoverAgentPollEndpoint"
        Effect   = "Allow"
        Action   = "ecs:DiscoverPollEndpoint"
        Resource = "*"
      },
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
      {
        Sid      = "ReadPinnedRuntimeBundleVersion"
        Effect   = "Allow"
        Action   = "s3:GetObjectVersion"
        Resource = "${aws_s3_bucket.runtime_artifacts.arn}/${local.spot_runtime_object_key}"
      },
      {
        Sid      = "ReadOriginTlsArchiveOnly"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.origin_tls.arn}/origin-tls/letsencrypt.tar.gz"
      },
      {
        Sid      = "ReadOriginVerificationToken"
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = aws_ssm_parameter.origin_verify_token.arn
      },
      {
        Sid      = "CompleteOwnLaunchLifecycleAction"
        Effect   = "Allow"
        Action   = "autoscaling:CompleteLifecycleAction"
        Resource = local.measurement_group_arn
      },
    ]
  })
}

resource "aws_iam_role" "ecs_task_execution_measurement" {
  count = local.measurement_count

  name        = local.measurement_task_execution_role_name
  description = "Demo measurement ECS task execution role: API image pull, runtime secrets and measurement task logs"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = local.measurement_task_execution_role_name
  }
}

# The production task execution role's three policies (ecs_application.tf) in
# one document, with the log group replaced by the measurement one.
resource "aws_iam_role_policy" "ecs_task_execution_measurement" {
  count = local.measurement_count

  name = "measurement-task-execution"
  role = aws_iam_role.ecs_task_execution_measurement[0].id

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
      {
        Sid    = "ReadApiRuntimeSecrets"
        Effect = "Allow"
        Action = "ssm:GetParameters"
        Resource = [
          aws_ssm_parameter.db_master_password.arn,
          aws_ssm_parameter.auth_jwt_secret.arn,
        ]
      },
      {
        Sid    = "WriteMeasurementTaskLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "${local.measurement_log_group_arn}:log-stream:*"
      },
    ]
  })
}
