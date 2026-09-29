# Phase 6C-3: the ECS cluster and the Spot capacity provider.
#
# No task definition and no service are defined here. This phase builds the
# capacity side only; what runs on it is Phase 6C-4.

resource "aws_ecs_cluster" "demo" {
  name = local.ecs_cluster_name

  # Container Insights is an additional CloudWatch charge for a Demo that runs
  # a few hours a day. Turned off explicitly rather than left to the account
  # default, which can be changed account-wide from outside this state.
  setting {
    name  = "containerInsights"
    value = "disabled"
  }

  tags = {
    Name = local.ecs_cluster_name
  }
}

# Managed scaling is off because the Auto Scaling group's desired capacity
# belongs to the schedule, not to ECS. With it enabled, ECS would size the
# group from task demand and the Phase 6C-5 scheduler and ECS would be two
# controllers fighting over one value.
#
# Managed termination protection is off as a consequence: it only has meaning
# for ECS-driven scale-in, which is what managed scaling would have done.
#
# Managed draining is on. It is the AWS default at creation, and it is what
# turns a Spot interruption into a graceful drain rather than tasks
# disappearing with the host. It works regardless of termination protection.
# ECS attaches its own EC2_INSTANCE_TERMINATING lifecycle hook to the group to
# implement this -- a different transition from the launch hook below, so the
# two do not interact.
resource "aws_ecs_capacity_provider" "ecs_spot" {
  name = local.ecs_spot_name

  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.ecs_spot.arn
    managed_draining               = "ENABLED"
    managed_termination_protection = "DISABLED"

    managed_scaling {
      status = "DISABLED"
    }
  }

  tags = {
    Name = local.ecs_spot_name
  }
}

# No default_capacity_provider_strategy on the cluster. A default would send
# any RunTask call that omitted a strategy to the Spot group, including calls
# made before Phase 6C-4 exists. The Phase 6C-4 service names its provider
# explicitly instead, which also makes the service definition say where its
# tasks land.
#
# replace_triggered_by is the provider's documented remedy for the deletion
# order: AWS refuses to delete a capacity provider while a cluster association
# still references it, so a change that forces the provider to be replaced has
# to recreate the association first.
resource "aws_ecs_cluster_capacity_providers" "demo" {
  cluster_name       = aws_ecs_cluster.demo.name
  capacity_providers = [aws_ecs_capacity_provider.ecs_spot.name]

  lifecycle {
    replace_triggered_by = [aws_ecs_capacity_provider.ecs_spot]
  }
}
