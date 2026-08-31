locals {
  scheduler_group_name = "${local.name_prefix}-runtime"
  scheduler_role_name  = "${local.name_prefix}-scheduler"

  runtime_schedules = {
    rds_start = {
      name                = "${local.name_prefix}-rds-start"
      schedule_expression = "cron(50 9 ? * MON-FRI *)"
      target_arn          = "arn:aws:scheduler:::aws-sdk:rds:startDBInstance"
      input = jsonencode({
        DBInstanceIdentifier = aws_db_instance.demo.identifier
      })
    }
    ec2_start = {
      name                = "${local.name_prefix}-ec2-start"
      schedule_expression = "cron(0 10 ? * MON-FRI *)"
      target_arn          = "arn:aws:scheduler:::aws-sdk:ec2:startInstances"
      input = jsonencode({
        InstanceIds = [aws_instance.demo.id]
      })
    }
    ec2_stop = {
      name                = "${local.name_prefix}-ec2-stop"
      schedule_expression = "cron(0 17 ? * MON-FRI *)"
      target_arn          = "arn:aws:scheduler:::aws-sdk:ec2:stopInstances"
      input = jsonencode({
        InstanceIds = [aws_instance.demo.id]
      })
    }
    rds_stop = {
      name                = "${local.name_prefix}-rds-stop"
      schedule_expression = "cron(10 17 ? * MON-FRI *)"
      target_arn          = "arn:aws:scheduler:::aws-sdk:rds:stopDBInstance"
      input = jsonencode({
        DBInstanceIdentifier = aws_db_instance.demo.identifier
      })
    }
  }
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

resource "aws_scheduler_schedule_group" "runtime" {
  name = local.scheduler_group_name

  tags = {
    Name = local.scheduler_group_name
  }
}

resource "aws_iam_role" "scheduler" {
  name        = local.scheduler_role_name
  description = "EventBridge Scheduler role for Demo EC2 and RDS lifecycle control"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "scheduler.amazonaws.com"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
          ArnEquals = {
            "aws:SourceArn" = aws_scheduler_schedule_group.runtime.arn
          }
        }
      }
    ]
  })

  tags = {
    Name = local.scheduler_role_name
  }
}

resource "aws_iam_role_policy" "scheduler_runtime_control" {
  name = "runtime-start-stop"
  role = aws_iam_role.scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ControlDemoEc2"
        Effect = "Allow"
        Action = [
          "ec2:StartInstances",
          "ec2:StopInstances",
        ]
        Resource = aws_instance.demo.arn
      },
      {
        Sid    = "ControlDemoRds"
        Effect = "Allow"
        Action = [
          "rds:StartDBInstance",
          "rds:StopDBInstance",
        ]
        Resource = aws_db_instance.demo.arn
      },
    ]
  })
}

resource "aws_scheduler_schedule" "runtime" {
  for_each = local.runtime_schedules

  name                         = each.value.name
  group_name                   = aws_scheduler_schedule_group.runtime.name
  schedule_expression          = each.value.schedule_expression
  schedule_expression_timezone = "Asia/Tokyo"
  state                        = "ENABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = each.value.target_arn
    role_arn = aws_iam_role.scheduler.arn
    input    = each.value.input

    retry_policy {
      maximum_event_age_in_seconds = 900
      maximum_retry_attempts       = 3
    }
  }

  depends_on = [aws_iam_role_policy.scheduler_runtime_control]
}
