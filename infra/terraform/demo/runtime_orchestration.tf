# Phase 6C-5c P3-a: the cold standby control plane, created inert.
#
# Five Step Functions workflows will run the weekday Spot origin with the
# stopped On-Demand host as its cold standby (PHASE6C5C-DEMO-P3-DESIGN.md).
# This file creates them, their roles, the control table, the EventBridge rules
# and the new schedules. Execution stays inert until separately approved arming:
#
#   - every new schedule and every new rule is DISABLED, and the scheduler role
#     keeps runtime-start-stop as it is (no states:StartExecution until P3-c0);
#   - every definition starts at ArmGate: it reads the control table's `mode`
#     and `maintenance` items and fails NotArmed unless an operator armed the
#     runtime (mode.enabled, scope, approvalRef, armedUntil for a rehearsal) and
#     no maintenance item exists. The table is created empty, so a manual
#     StartExecution after this apply ends at NotArmed without a write;
#   - working definitions fence every write against current operator approval,
#     maintenance, execution identity, lease and deadline. The role grants are
#     in runtime_iam.tf; only origin-guard can associate the EIP.
#
# Existing resources are not changed: the On-Demand host, the database, the
# origin EIP, the Spot group and template, the four legacy schedules, the
# scheduler role and its policy, and the alert topic and its policy.
#
# The names are the ones the Access IaC grants (Phase 6C-5c cold standby runtime
# permissions in infra/terraform/access/README.md). A different name fails
# closed with an AccessDenied rather than widening anything.

locals {
  runtime_control_table_name     = "${local.name_prefix}-runtime-control"
  runtime_orchestrator_role_name = "${local.name_prefix}-runtime-orchestrator"
  runtime_eip_writer_role_name   = "${local.name_prefix}-runtime-eip-writer"
  runtime_events_role_name       = "${local.name_prefix}-runtime-events"

  # A lease is the workflow's own timeout plus this margin (design 2.5).
  runtime_lease_margin_seconds = 600

  # origin-guard is the single writer of the origin EIP association and the only
  # workflow with the eip-writer role; the other four run as the orchestrator.
  runtime_workflows = {
    day_open = {
      name            = "${local.name_prefix}-day-open"
      definition      = "day-open.asl.json"
      timeout_seconds = 3600
      role            = "orchestrator"
    }
    ready_check = {
      name            = "${local.name_prefix}-ready-check"
      definition      = "ready-check.asl.json"
      timeout_seconds = 600
      role            = "orchestrator"
    }
    day_close = {
      name            = "${local.name_prefix}-day-close"
      definition      = "day-close.asl.json"
      timeout_seconds = 9000
      role            = "orchestrator"
    }
    origin_guard = {
      name            = "${local.name_prefix}-origin-guard"
      definition      = "origin-guard.asl.json"
      timeout_seconds = 1800
      role            = "eip_writer"
    }
    od_standby = {
      name            = "${local.name_prefix}-od-standby"
      definition      = "od-standby.asl.json"
      timeout_seconds = 2700
      role            = "orchestrator"
    }
  }

  # Built from the names rather than read from the resources: the roles' trust
  # needs them before the state machines exist. A postcondition on each state
  # machine checks they match.
  runtime_state_machine_arns = {
    for key, workflow in local.runtime_workflows :
    key => "arn:${data.aws_partition.current.partition}:states:${local.aws_region}:${data.aws_caller_identity.current.account_id}:stateMachine:${workflow.name}"
  }

  runtime_orchestrator_workflows = [for key, workflow in local.runtime_workflows : key if workflow.role == "orchestrator"]

  # Also built from names, so every policy and trust document below is known at
  # plan time and the plan gate can read it in full. Postconditions check them.
  runtime_control_table_arn = "arn:${data.aws_partition.current.partition}:dynamodb:${local.aws_region}:${data.aws_caller_identity.current.account_id}:table/${local.runtime_control_table_name}"
  runtime_signals_rule_name = "${local.name_prefix}-origin-guard-signals"
  runtime_signals_rule_arn  = "arn:${data.aws_partition.current.partition}:events:${local.aws_region}:${data.aws_caller_identity.current.account_id}:rule/${local.runtime_signals_rule_name}"

  # Scheduler keys -> the workflow each one starts. T_open 07:15 is provisional
  # (design 1.2); the last night backstop must stay ahead of it.
  runtime_orchestration_schedules = {
    day_open = {
      name                = "${local.name_prefix}-day-open"
      workflow            = "day_open"
      schedule_expression = "cron(15 7 ? * MON-FRI *)"
    }
    ready_check = {
      name                = "${local.name_prefix}-ready-check"
      workflow            = "ready_check"
      schedule_expression = "cron(0 8 ? * MON-FRI *)"
    }
    day_close = {
      name                = "${local.name_prefix}-day-close"
      workflow            = "day_close"
      schedule_expression = "cron(0 22 ? * MON-FRI *)"
    }
    origin_guard_tick = {
      name                = "${local.name_prefix}-origin-guard-tick"
      workflow            = "origin_guard"
      schedule_expression = "cron(0/30 8-21 ? * MON-FRI *)"
    }
  }

  # A rehearsal arming may last at most this long (design 13.3).
  runtime_rehearsal_arming_max_ms = 4 * 3600 * 1000
}

# One item per concern, keyed by pk alone (design 1.5). Created empty: with no
# `mode` item every workflow stops at ArmGate. ttl only ever cleans up.
resource "aws_dynamodb_table" "runtime_control" {
  name         = local.runtime_control_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"

  deletion_protection_enabled = true

  attribute {
    name = "pk"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  tags = {
    Name = local.runtime_control_table_name
  }

  lifecycle {
    postcondition {
      condition     = self.arn == local.runtime_control_table_arn
      error_message = "The control table ARN differs from the one the role policies name."
    }
  }
}

resource "aws_iam_role" "runtime_orchestrator" {
  name        = local.runtime_orchestrator_role_name
  description = "Demo cold standby workflows: day-open, ready-check, day-close, od-standby"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "states.amazonaws.com"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
          ArnEquals = {
            "aws:SourceArn" = [for key in local.runtime_orchestrator_workflows : local.runtime_state_machine_arns[key]]
          }
        }
      }
    ]
  })

  tags = {
    Name = local.runtime_orchestrator_role_name
  }
}

resource "aws_iam_role" "runtime_eip_writer" {
  name        = local.runtime_eip_writer_role_name
  description = "Demo origin-guard: the single writer of the origin EIP association"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "states.amazonaws.com"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
          ArnEquals = {
            "aws:SourceArn" = local.runtime_state_machine_arns.origin_guard
          }
        }
      }
    ]
  })

  tags = {
    Name = local.runtime_eip_writer_role_name
  }
}

# Logging, tracing and versions stay off: the Access grants do not cover them,
# and every failure reaches the alert topic through runtime_orchestration_failed
# once it is enabled.
resource "aws_sfn_state_machine" "runtime" {
  for_each = local.runtime_workflows

  name     = each.value.name
  type     = "STANDARD"
  role_arn = each.value.role == "eip_writer" ? aws_iam_role.runtime_eip_writer.arn : aws_iam_role.runtime_orchestrator.arn

  definition = templatefile("${path.module}/state-machines/${each.value.definition}", {
    table_name                 = local.runtime_control_table_name
    timeout_seconds            = each.value.timeout_seconds
    rehearsal_arming_max_ms    = local.runtime_rehearsal_arming_max_ms
    lease_ms                   = (each.value.timeout_seconds + local.runtime_lease_margin_seconds) * 1000
    write_window_ms            = each.value.timeout_seconds * 1000
    write_margin_ms            = 120000
    partition                  = data.aws_partition.current.partition
    account_id                 = data.aws_caller_identity.current.account_id
    region                     = local.aws_region
    asg_name                   = local.ecs_spot_name
    db_instance_identifier     = aws_db_instance.demo.identifier
    od_instance_id             = aws_instance.demo.id
    od_eni_id                  = aws_instance.demo.primary_network_interface_id
    eip_allocation_id          = aws_eip.ec2_origin.allocation_id
    spot_instance_profile_arn  = aws_iam_instance_profile.ecs_spot.arn
    od_instance_profile_arn    = aws_iam_instance_profile.ec2.arn
    ecs_cluster_arn            = aws_ecs_cluster.demo.arn
    ecs_service_name           = aws_ecs_service.api.name
    desired_image_parameter    = aws_ssm_parameter.deploy_desired_image_sha.name
    od_readiness_document_name = "${local.name_prefix}-od-readiness"
    spot_smoke_document_name   = "${local.name_prefix}-spot-smoke"
    origin_guard_arn           = local.runtime_state_machine_arns.origin_guard
    od_standby_arn             = local.runtime_state_machine_arns.od_standby
    cloudfront_domain          = aws_cloudfront_distribution.api.domain_name
    expected_image_sha         = local.ecs_api_image_sha
    expected_image_repository  = aws_ecr_repository.demo_api.repository_url
    scheduler_group_name       = "${local.name_prefix}-runtime"
    name_prefix                = local.name_prefix
  })

  tags = {
    Name = each.value.name
  }

  lifecycle {
    postcondition {
      condition     = self.arn == local.runtime_state_machine_arns[each.key]
      error_message = "The state machine ARN differs from the one its role trusts."
    }
  }

  depends_on = [
    aws_iam_role_policy.runtime_orchestrator,
    aws_iam_role_policy.runtime_eip_writer,
  ]
}

# EventBridge cannot start an execution without a role of its own. This one can
# start origin-guard and od-standby, and only for the signals rule.
resource "aws_iam_role" "runtime_events" {
  name        = local.runtime_events_role_name
  description = "Demo origin-guard signals rule: start origin-guard and od-standby only"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
          ArnEquals = {
            "aws:SourceArn" = local.runtime_signals_rule_arn
          }
        }
      }
    ]
  })

  tags = {
    Name = local.runtime_events_role_name
  }
}

resource "aws_iam_role_policy" "runtime_events" {
  name = "start-signal-workflows"
  role = aws_iam_role.runtime_events.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "StartSignalWorkflows"
        Effect = "Allow"
        Action = "states:StartExecution"
        Resource = [
          local.runtime_state_machine_arns.origin_guard,
          local.runtime_state_machine_arns.od_standby,
        ]
      },
    ]
  })
}

# The signals the guard and the standby act on (design 2.1). The Spot notices
# carry only an instance ID, so they cannot be narrowed to the group here; the
# Auto Scaling and ECS events are narrowed to the production group and service,
# and the instance state change to the On-Demand host.
resource "aws_cloudwatch_event_rule" "origin_guard_signals" {
  name        = local.runtime_signals_rule_name
  description = "Spot interruption, rebalance, production group, API task and On-Demand host signals for the cold standby"
  state       = "DISABLED"

  event_pattern = jsonencode({
    "$or" = [
      {
        source = ["aws.ec2"]
        "detail-type" = [
          "EC2 Spot Instance Interruption Warning",
          "EC2 Instance Rebalance Recommendation",
        ]
      },
      {
        source = ["aws.autoscaling"]
        "detail-type" = [
          "EC2 Instance-terminate Lifecycle Action",
          "EC2 Instance Launch Successful",
          "EC2 Instance Launch Unsuccessful",
        ]
        detail = {
          AutoScalingGroupName = [aws_autoscaling_group.ecs_spot.name]
        }
      },
      {
        source        = ["aws.ecs"]
        "detail-type" = ["ECS Task State Change"]
        detail = {
          clusterArn = [aws_ecs_cluster.demo.arn]
          group      = ["service:${aws_ecs_service.api.name}"]
          lastStatus = ["STOPPED"]
        }
      },
      {
        source        = ["aws.ec2"]
        "detail-type" = ["EC2 Instance State-change Notification"]
        detail = {
          "instance-id" = [aws_instance.demo.id]
        }
      },
    ]
  })

  tags = {
    Name = local.runtime_signals_rule_name
  }

  lifecycle {
    postcondition {
      condition     = self.arn == local.runtime_signals_rule_arn
      error_message = "The signals rule ARN differs from the one the events role trusts."
    }
  }
}

resource "aws_cloudwatch_event_target" "origin_guard_signals_origin_guard" {
  rule      = aws_cloudwatch_event_rule.origin_guard_signals.name
  target_id = "origin-guard"
  arn       = aws_sfn_state_machine.runtime["origin_guard"].arn
  role_arn  = aws_iam_role.runtime_events.arn

  input_transformer {
    input_paths    = { time = "$.time" }
    input_template = "{\"trigger\":\"event\",\"scheduledTime\":<time>,\"event\":<aws.events.event.json>}"
  }

  depends_on = [aws_iam_role_policy.runtime_events]
}

resource "aws_cloudwatch_event_target" "origin_guard_signals_od_standby" {
  rule      = aws_cloudwatch_event_rule.origin_guard_signals.name
  target_id = "od-standby"
  arn       = aws_sfn_state_machine.runtime["od_standby"].arn
  role_arn  = aws_iam_role.runtime_events.arn

  input_transformer {
    input_paths    = { time = "$.time" }
    input_template = "{\"trigger\":\"event\",\"scheduledTime\":<time>,\"event\":<aws.events.event.json>}"
  }

  depends_on = [aws_iam_role_policy.runtime_events]
}

# Notification only. The topic policy gains its events statement in P3-c0,
# before this rule is enabled in P3-c.
resource "aws_cloudwatch_event_rule" "spot_capacity_unavailable" {
  name        = "${local.name_prefix}-spot-capacity-unavailable"
  description = "A production Spot launch failed"
  state       = "DISABLED"

  event_pattern = jsonencode({
    source        = ["aws.autoscaling"]
    "detail-type" = ["EC2 Instance Launch Unsuccessful"]
    detail = {
      AutoScalingGroupName = [aws_autoscaling_group.ecs_spot.name]
    }
  })

  tags = {
    Name = "${local.name_prefix}-spot-capacity-unavailable"
  }
}

# Only the group name is placed in the message: values from an event are not
# escaped into the template.
resource "aws_cloudwatch_event_target" "spot_capacity_unavailable" {
  rule      = aws_cloudwatch_event_rule.spot_capacity_unavailable.name
  target_id = "alerts"
  arn       = aws_sns_topic.alerts.arn

  input_transformer {
    input_paths = {
      group = "$.detail.AutoScalingGroupName"
    }
    input_template = "\"Demo Spot launch failed in <group>. The cold standby decides whether the On-Demand host takes the origin; see the group's activity history.\""
  }
}

# FAILED, TIMED_OUT and ABORTED alike: a timed-out or aborted execution runs no
# Catch, so this rule is the only report of it.
resource "aws_cloudwatch_event_rule" "runtime_orchestration_failed" {
  name        = "${local.name_prefix}-runtime-orchestration-failed"
  description = "A Demo cold standby workflow did not succeed"
  state       = "DISABLED"

  event_pattern = jsonencode({
    source        = ["aws.states"]
    "detail-type" = ["Step Functions Execution Status Change"]
    detail = {
      status          = ["FAILED", "TIMED_OUT", "ABORTED"]
      stateMachineArn = values(local.runtime_state_machine_arns)
    }
  })

  tags = {
    Name = "${local.name_prefix}-runtime-orchestration-failed"
  }
}

resource "aws_cloudwatch_event_target" "runtime_orchestration_failed" {
  rule      = aws_cloudwatch_event_rule.runtime_orchestration_failed.name
  target_id = "alerts"
  arn       = aws_sns_topic.alerts.arn

  input_transformer {
    input_paths = {
      execution = "$.detail.executionArn"
      status    = "$.detail.status"
    }
    input_template = "\"Demo cold standby workflow <execution> ended <status>. Check the execution's error before the next scheduled run.\""
  }
}

# Created DISABLED, with the existing scheduler role: its trust names the
# schedule group, which these share with the legacy schedules. That role has no
# states:StartExecution until P3-c0, so an enabled schedule could not start a
# workflow either. The scheduled time is the run's identity.
resource "aws_scheduler_schedule" "runtime_orchestration" {
  for_each = local.runtime_orchestration_schedules

  name                         = each.value.name
  group_name                   = aws_scheduler_schedule_group.runtime.name
  schedule_expression          = each.value.schedule_expression
  schedule_expression_timezone = "Asia/Tokyo"
  state                        = "DISABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_sfn_state_machine.runtime[each.value.workflow].arn
    role_arn = aws_iam_role.scheduler.arn
    input = jsonencode(merge({
      trigger       = "scheduler"
      scheduledTime = "<aws.scheduler.scheduled-time>"
    }, each.key == "day_close" ? { rdsStop = "schedule", parkEip = "od" } : {}))

    retry_policy {
      maximum_event_age_in_seconds = 900
      maximum_retry_attempts       = 3
    }
  }
}
