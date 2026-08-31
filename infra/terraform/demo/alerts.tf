locals {
  alert_topic_name             = "${local.name_prefix}-alerts"
  scheduler_failure_alarm_name = "${local.name_prefix}-scheduler-invocation-dropped"
  monthly_budget_name          = "${local.name_prefix}-monthly-cost"
  monthly_budget_limit_usd     = "30.30"

  scheduler_failure_alarm_arn = "arn:${data.aws_partition.current.partition}:cloudwatch:${local.aws_region}:${data.aws_caller_identity.current.account_id}:alarm:${local.scheduler_failure_alarm_name}"
  monthly_budget_arn          = "arn:${data.aws_partition.current.partition}:budgets::${data.aws_caller_identity.current.account_id}:budget/${local.monthly_budget_name}"
}

resource "aws_sns_topic" "alerts" {
  name = local.alert_topic_name

  tags = {
    Name = local.alert_topic_name
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn = aws_sns_topic.alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowBudgetNotifications"
        Effect = "Allow"
        Principal = {
          Service = "budgets.amazonaws.com"
        }
        Action   = "sns:Publish"
        Resource = aws_sns_topic.alerts.arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
          ArnEquals = {
            "aws:SourceArn" = local.monthly_budget_arn
          }
        }
      },
      {
        Sid    = "AllowSchedulerAlarmNotifications"
        Effect = "Allow"
        Principal = {
          Service = "cloudwatch.amazonaws.com"
        }
        Action   = "sns:Publish"
        Resource = aws_sns_topic.alerts.arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
          ArnEquals = {
            "aws:SourceArn" = local.scheduler_failure_alarm_arn
          }
        }
      },
    ]
  })
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_metric_alarm" "scheduler_invocation_dropped" {
  alarm_name          = local.scheduler_failure_alarm_name
  alarm_description   = "Alerts when EventBridge Scheduler exhausts retries for the Demo runtime group."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "InvocationDroppedCount"
  namespace           = "AWS/Scheduler"
  period              = 60
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    ScheduleGroup = aws_scheduler_schedule_group.runtime.name
  }

  depends_on = [aws_sns_topic_policy.alerts]

  tags = {
    Name = local.scheduler_failure_alarm_name
  }
}

resource "aws_budgets_budget" "monthly_cost" {
  name         = local.monthly_budget_name
  budget_type  = "COST"
  limit_amount = local.monthly_budget_limit_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_types {
    include_credit             = false
    include_discount           = true
    include_other_subscription = true
    include_recurring          = true
    include_refund             = false
    include_subscription       = true
    include_support            = true
    include_tax                = true
    include_upfront            = true
    use_amortized              = false
    use_blended                = false
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    notification_type         = "ACTUAL"
    threshold                 = 70
    threshold_type            = "PERCENTAGE"
    subscriber_sns_topic_arns = [aws_sns_topic.alerts.arn]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    notification_type         = "ACTUAL"
    threshold                 = 90
    threshold_type            = "PERCENTAGE"
    subscriber_sns_topic_arns = [aws_sns_topic.alerts.arn]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    notification_type         = "FORECASTED"
    threshold                 = 90
    threshold_type            = "PERCENTAGE"
    subscriber_sns_topic_arns = [aws_sns_topic.alerts.arn]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    notification_type         = "ACTUAL"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    subscriber_sns_topic_arns = [aws_sns_topic.alerts.arn]
  }

  depends_on = [aws_sns_topic_policy.alerts]

  tags = {
    Name = local.monthly_budget_name
  }
}
