# Runtime grants are limited to the resources and actions called by the five
# workflows. No existing scheduler or alert policy is changed in P3-a.

locals {
  runtime_ec2_instance_prefix = "arn:${data.aws_partition.current.partition}:ec2:${local.aws_region}:${data.aws_caller_identity.current.account_id}:instance/"
  runtime_od_eni_arn          = "arn:${data.aws_partition.current.partition}:ec2:${local.aws_region}:${data.aws_caller_identity.current.account_id}:network-interface/${aws_instance.demo.primary_network_interface_id}"
  runtime_eip_arn             = "arn:${data.aws_partition.current.partition}:ec2:${local.aws_region}:${data.aws_caller_identity.current.account_id}:elastic-ip/${aws_eip.ec2_origin.allocation_id}"
  runtime_command_arns = [
    "arn:${data.aws_partition.current.partition}:ssm:${local.aws_region}:${data.aws_caller_identity.current.account_id}:document/${local.name_prefix}-od-readiness",
    "arn:${data.aws_partition.current.partition}:ssm:${local.aws_region}:${data.aws_caller_identity.current.account_id}:document/${local.name_prefix}-spot-smoke",
  ]
  runtime_legacy_schedule_arns = [for suffix in ["rds-start", "ec2-start", "ec2-stop", "rds-stop"] : "arn:${data.aws_partition.current.partition}:scheduler:${local.aws_region}:${data.aws_caller_identity.current.account_id}:schedule/${local.name_prefix}-runtime/${local.name_prefix}-${suffix}"]

  # Transaction IAM authorization uses the constituent Get/Put/Update/Delete
  # and ConditionCheckItem actions, not a dynamodb:TransactWriteItems grant.
  runtime_control_read = {
    Sid      = "ReadRuntimeControl"
    Effect   = "Allow"
    Action   = ["dynamodb:GetItem"]
    Resource = local.runtime_control_table_arn
    Condition = {
      "ForAllValues:StringLike" = {
        "dynamodb:LeadingKeys" = ["mode", "maintenance", "standby-hold", "lock#runtime", "run#*", "ready#*", "day#*", "instance#*", "promotion"]
      }
      Null = { "dynamodb:LeadingKeys" = "false" }
    }
  }
  runtime_control_conditions = {
    Sid      = "CheckRuntimeFence"
    Effect   = "Allow"
    Action   = ["dynamodb:ConditionCheckItem"]
    Resource = local.runtime_control_table_arn
    Condition = {
      "ForAllValues:StringLike" = {
        "dynamodb:LeadingKeys" = ["mode", "maintenance", "standby-hold", "lock#runtime", "run#*", "ready#*", "day#*", "instance#*", "promotion"]
      }
      Null = { "dynamodb:LeadingKeys" = "false" }
    }
  }
  # PutItem cannot create mode/arming. Workflow code only updates state and
  # audit fields after checking the existing operator-owned approval fields.
  runtime_mode_update = {
    Sid      = "UpdateExistingMode"
    Effect   = "Allow"
    Action   = ["dynamodb:UpdateItem"]
    Resource = local.runtime_control_table_arn
    Condition = {
      "ForAllValues:StringEquals" = { "dynamodb:LeadingKeys" = ["mode"] }
      Null                        = { "dynamodb:LeadingKeys" = "false" }
    }
  }
  runtime_describe = {
    Sid    = "ObserveRuntime"
    Effect = "Allow"
    Action = [
      "autoscaling:DescribeAutoScalingGroups", "ec2:DescribeInstances",
      "ec2:DescribeAddresses", "ec2:DescribeNetworkInterfaceAttribute",
      "ecs:DescribeTaskDefinition",
    ]
    Resource = "*"
  }
  runtime_services = {
    Sid      = "ObserveProductionService"
    Effect   = "Allow"
    Action   = ["ecs:DescribeServices"]
    Resource = aws_ecs_service.api.id
  }
  runtime_database_read = {
    Sid      = "ObserveRuntimeDatabase"
    Effect   = "Allow"
    Action   = ["rds:DescribeDBInstances"]
    Resource = aws_db_instance.demo.arn
  }
  runtime_legacy_reads = {
    Sid      = "CheckLegacyScheduleExclusion"
    Effect   = "Allow"
    Action   = ["scheduler:GetSchedule"]
    Resource = local.runtime_legacy_schedule_arns
  }
  runtime_ssm_documents = {
    Sid      = "SendReviewedCommands"
    Effect   = "Allow"
    Action   = ["ssm:SendCommand"]
    Resource = local.runtime_command_arns
  }
  runtime_ssm_od = {
    Sid      = "CommandOnDemand"
    Effect   = "Allow"
    Action   = ["ssm:SendCommand"]
    Resource = aws_instance.demo.arn
  }
  runtime_ssm_spot = {
    Sid      = "CommandProductionSpotOnly"
    Effect   = "Allow"
    Action   = ["ssm:SendCommand"]
    Resource = "${local.runtime_ec2_instance_prefix}*"
    Condition = {
      StringEquals = { "ssm:resourceTag/aws:autoscaling:groupName" = local.ecs_spot_name }
      Null         = { "ssm:resourceTag/aws:autoscaling:groupName" = "false" }
    }
  }
}

resource "aws_iam_role_policy" "runtime_orchestrator" {
  name = "runtime-orchestration"
  role = aws_iam_role.runtime_orchestrator.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      local.runtime_control_read, local.runtime_control_conditions,
      local.runtime_mode_update, local.runtime_describe, local.runtime_services,
      local.runtime_database_read, local.runtime_legacy_reads,
      local.runtime_ssm_documents, local.runtime_ssm_od, local.runtime_ssm_spot,
      {
        Sid      = "WriteWorkflowRecords", Effect = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem"]
        Resource = local.runtime_control_table_arn
        Condition = {
          "ForAllValues:StringLike" = { "dynamodb:LeadingKeys" = ["run#*", "lock#runtime", "ready#*", "day#*", "instance#*"] }
          Null                      = { "dynamodb:LeadingKeys" = "false" }
        }
      },
      {
        Sid    = "ScaleProductionSpot", Effect = "Allow"
        Action = ["autoscaling:SetDesiredCapacity"], Resource = aws_autoscaling_group.ecs_spot.arn
      },
      {
        Sid    = "DatabaseRuntime", Effect = "Allow"
        Action = ["rds:StartDBInstance", "rds:StopDBInstance"], Resource = aws_db_instance.demo.arn
      },
      {
        Sid    = "ColdStandbyLifecycle", Effect = "Allow"
        Action = ["ec2:StartInstances", "ec2:StopInstances"], Resource = aws_instance.demo.arn
      },
      {
        Sid    = "ColdStandbyPublicIpv4", Effect = "Allow"
        Action = ["ec2:ModifyNetworkInterfaceAttribute"], Resource = [local.runtime_od_eni_arn, aws_instance.demo.arn]
        Condition = {
          StringEquals = { "ec2:Attribute/AssociatePublicIpAddress" = ["true", "false"] }
          Null         = { "ec2:Attribute/AssociatePublicIpAddress" = "false" }
        }
      },
      {
        Sid    = "PinColdStandbyRelease", Effect = "Allow"
        Action = ["ssm:PutParameter"], Resource = aws_ssm_parameter.deploy_desired_image_sha.arn
      },
      {
        Sid    = "ObserveCommands", Effect = "Allow"
        Action = ["ssm:DescribeInstanceInformation", "ssm:GetCommandInvocation"], Resource = "*"
      },
      {
        Sid    = "StartRuntimeChildren", Effect = "Allow"
        Action = ["states:StartExecution"], Resource = [local.runtime_state_machine_arns.origin_guard, local.runtime_state_machine_arns.od_standby]
      },
    ])
  })
}

resource "aws_iam_role_policy" "runtime_eip_writer" {
  name = "origin-eip-writer"
  role = aws_iam_role.runtime_eip_writer.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      local.runtime_control_read, local.runtime_control_conditions,
      local.runtime_mode_update, local.runtime_describe, local.runtime_services,
      local.runtime_database_read, local.runtime_legacy_reads,
      {
        Sid      = "WritePromotionRecords", Effect = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem"]
        Resource = local.runtime_control_table_arn
        Condition = {
          "ForAllValues:StringLike" = { "dynamodb:LeadingKeys" = ["run#origin-guard#*", "lock#runtime", "promotion", "instance#*", "ready#*"] }
          Null                      = { "dynamodb:LeadingKeys" = "false" }
        }
      },
      {
        Sid      = "CountDailySignals"
        Effect   = "Allow"
        Action   = ["dynamodb:UpdateItem"]
        Resource = local.runtime_control_table_arn
        Condition = {
          "ForAllValues:StringLike" = { "dynamodb:LeadingKeys" = ["day#*"] }
          Null                      = { "dynamodb:LeadingKeys" = "false" }
        }
      },
      {
        Sid    = "AssociateExactOriginEip", Effect = "Allow"
        Action = ["ec2:AssociateAddress"], Resource = local.runtime_eip_arn
      },
      {
        Sid    = "AssociateColdStandby", Effect = "Allow"
        Action = ["ec2:AssociateAddress"], Resource = aws_instance.demo.arn
      },
      {
        Sid    = "AssociateProductionSpot", Effect = "Allow"
        Action = ["ec2:AssociateAddress"], Resource = "${local.runtime_ec2_instance_prefix}*"
        Condition = {
          StringEquals = { "ec2:InstanceMarketType" = "spot", "ec2:InstanceProfile" = aws_iam_instance_profile.ecs_spot.arn }
          Null         = { "ec2:InstanceMarketType" = "false", "ec2:InstanceProfile" = "false" }
        }
      },
      {
        Sid    = "StartColdStandby", Effect = "Allow"
        Action = ["states:StartExecution"], Resource = local.runtime_state_machine_arns.od_standby
      },
    ]
  })
}
