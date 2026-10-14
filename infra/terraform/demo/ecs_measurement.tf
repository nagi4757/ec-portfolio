# Phase 6C-5c: the separate measurement stack for sizing the Spot host.
#
# Whether the Spot host can move from t3a.medium to t3a.small depends on host
# memory that no production metric reports, and measuring it on the production
# capacity would mean changing the production task definition, which restarts
# the API on every host. This stack runs the same task beside production
# instead: its own cluster, task definition, service, launch template, Auto
# Scaling group and roles, sharing only what it reads (network, security group,
# database, parameters, image, runtime bundle and origin TLS archive).
#
# Nothing in a production file changes. The task definition is derived from the
# production one's container definitions, read from that resource, so the
# measurement runs exactly the production API and Valkey.
#
# The names are fixed by the Access IaC (Phase 6C-5c measurement stack
# permissions in infra/terraform/access/README.md). A different name fails
# closed with an AccessDenied rather than widening anything.

locals {
  # The switch, as code rather than a variable: turning the stack on, switching
  # the instance type and turning it off are each a reviewed change, so main
  # always matches what exists and nobody's plan removes the stack by leaving a
  # -var out. Off on main.
  measurement_stack_enabled = true

  # t3a.medium for the baseline runs, then t3a.small. Same CPU, half the memory.
  measurement_instance_type = "t3a.medium"

  measurement_allowed_instance_types = ["t3a.medium", "t3a.small"]
  measurement_count                  = local.measurement_stack_enabled ? 1 : 0

  measurement_cluster_name             = "${local.name_prefix}-measure"
  measurement_name                     = "${local.name_prefix}-ecs-spot-measure"
  measurement_lifecycle_hook_name      = "${local.measurement_name}-launching"
  measurement_log_group_name           = "/ec-portfolio/demo/ecs/measure"
  measurement_task_execution_role_name = "${local.name_prefix}-ecs-task-execution-measure"
  measurement_family                   = "${local.name_prefix}-api-measure"
  measurement_service_name             = "${local.name_prefix}-api-measure"

  # The production loader, pointed at the measurement cluster, group and hook,
  # and opted out of the origin Elastic IP promotion. With an empty allocation
  # bootstrap-spot-host.sh neither installs nor queues the promotion unit, and
  # promote-origin-eip.sh refuses to run (both covered by the runtime tests).
  measurement_user_data_variables = merge(local.spot_user_data_variables, {
    ecs_cluster_name         = local.measurement_cluster_name
    autoscaling_group_name   = local.measurement_name
    lifecycle_hook_name      = local.measurement_lifecycle_hook_name
    origin_eip_allocation_id = ""
  })

  measurement_user_data = templatefile(local.spot_user_data_template, local.measurement_user_data_variables)

  # The same plan-time upper bound as the production template's.
  measurement_user_data_size_upper_bound = templatefile(
    local.spot_user_data_template,
    merge(local.measurement_user_data_variables, {
      runtime_bucket            = format("%063d", 0)
      runtime_object_version_id = format("%01024d", 0)
    }),
  )

  # Unified GC logging to stdout, so the measurement API's log stream carries
  # the heap's configured maximum (gc+init) and every collection. Only the
  # measurement task gets it.
  measurement_gc_log_option = "-Xlog:gc,gc+init:stdout:uptime,level,tags"

  # The production container definitions as Terraform last read them back, so
  # the measurement task runs what production runs.
  measurement_production_containers = jsondecode(aws_ecs_task_definition.api.container_definitions)

  # Only two things change: every container logs to the measurement log group
  # under a measure- prefix, and the API adds GC logging.
  measurement_derived_containers = [
    for container in local.measurement_production_containers : merge(container, {
      environment = [
        for variable in try(container.environment, []) : variable.name == "JAVA_TOOL_OPTIONS" ? {
          name  = variable.name
          value = "${variable.value} ${local.measurement_gc_log_option}"
        } : variable
      ]

      logConfiguration = merge(container.logConfiguration, {
        options = merge(container.logConfiguration.options, {
          awslogs-group         = local.measurement_log_group_name
          awslogs-stream-prefix = "measure-${container.name}"
        })
      })
    })
  ]

  # The two helpers run as nobody, like the probe in ecs-memory-probe.test.sh,
  # and not as 0, so the IMDS guard rejects them as well.
  measurement_helper_user = "65534:65534"

  # 5-second samples for the first 15 minutes, which cover the cold start, then
  # every 30 seconds. ecs-memory-probe.sh bounds each value.
  measurement_probe_environment = {
    MEMORY_PROBE_FAST_INTERVAL_SECONDS = "5"
    MEMORY_PROBE_FAST_WINDOW_SECONDS   = "900"
    MEMORY_PROBE_INTERVAL_SECONDS      = "30"
  }

  # Idle until 30 minutes after start (cold start and a steady idle period),
  # then 20 minutes of GET requests at 2 per second, then idle again.
  # ecs-measurement-load.sh bounds each value; the target is fixed in the script.
  measurement_load_environment = {
    LOAD_DURATION_SECONDS      = "1200"
    LOAD_RATE_PER_SECOND       = "2"
    LOAD_READY_TIMEOUT_SECONDS = "900"
    LOAD_START_DELAY_SECONDS   = "1800"
  }

  # Both helpers: the pinned Valkey image (BusyBox sh, awk, wget), so no new
  # image source; not essential, so a helper that stops never stops the task;
  # read-only root, no capability, no new privileges, no port, volume, host
  # mount or task role. 16 MiB reserved and 32 MiB hard, so a fault cannot take
  # memory from the API. Each exits on SIGTERM; stopTimeout only bounds a stop
  # it does not answer.
  measurement_helper_containers = [
    {
      name                   = "memory-probe"
      image                  = local.ecs_valkey_image
      essential              = false
      user                   = local.measurement_helper_user
      privileged             = false
      readonlyRootFilesystem = true
      dockerSecurityOptions  = ["no-new-privileges"]
      memoryReservation      = 16
      memory                 = 32
      stopTimeout            = 5

      linuxParameters = {
        capabilities = {
          drop = ["ALL"]
        }
      }

      entryPoint = ["/bin/sh", "-c"]
      command    = [file("${local.spot_runtime_source_directory}/ecs-memory-probe.sh")]

      environment = [
        for name in sort(keys(local.measurement_probe_environment)) : {
          name  = name
          value = local.measurement_probe_environment[name]
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = local.measurement_log_group_name
          awslogs-region        = local.aws_region
          awslogs-stream-prefix = "memory-probe"
        }
      }
    },
    {
      name                   = "load-driver"
      image                  = local.ecs_valkey_image
      essential              = false
      user                   = local.measurement_helper_user
      privileged             = false
      readonlyRootFilesystem = true
      dockerSecurityOptions  = ["no-new-privileges"]
      memoryReservation      = 16
      memory                 = 32
      stopTimeout            = 5

      linuxParameters = {
        capabilities = {
          drop = ["ALL"]
        }
      }

      entryPoint = ["/bin/sh", "-c"]
      command    = [file("${local.spot_runtime_source_directory}/ecs-measurement-load.sh")]

      environment = [
        for name in sort(keys(local.measurement_load_environment)) : {
          name  = name
          value = local.measurement_load_environment[name]
        }
      ]

      # Started once the API container has started; it then waits for the
      # API's readiness itself, so it never holds the task back.
      dependsOn = [
        {
          containerName = "api"
          condition     = "START"
        },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = local.measurement_log_group_name
          awslogs-region        = local.aws_region
          awslogs-stream-prefix = "load-driver"
        }
      }
    },
  ]

  measurement_container_definitions = concat(local.measurement_derived_containers, local.measurement_helper_containers)

  # Fail-closed checks on the derivation, evaluated in the plan that enables
  # the stack. Each holds for the production task definition on main.
  measurement_production_api = one([for container in local.measurement_production_containers : container if container.name == "api"])
  measurement_derived_api    = one([for container in local.measurement_derived_containers : container if container.name == "api"])
  measurement_java_tool_options = [
    for variable in try(local.measurement_derived_api.environment, []) : variable.value
    if variable.name == "JAVA_TOOL_OPTIONS"
  ]
}

resource "aws_ecs_cluster" "measurement" {
  count = local.measurement_count

  name = local.measurement_cluster_name

  setting {
    name  = "containerInsights"
    value = "disabled"
  }

  tags = {
    Name = local.measurement_cluster_name
  }
}

# Its own log group, so the production log group, and the observers and the
# cutover proof that read it, never see a measurement event. Deleted with the
# stack: the run evidence is copied out before the teardown.
resource "aws_cloudwatch_log_group" "measurement" {
  count = local.measurement_count

  name              = local.measurement_log_group_name
  retention_in_days = 7

  tags = {
    Name = "${local.name_prefix}-ecs-measure"
  }
}

resource "aws_ecs_task_definition" "measurement" {
  count = local.measurement_count

  family                   = local.measurement_family
  network_mode             = "host"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = aws_iam_role.ecs_task_execution_measurement[0].arn

  container_definitions = jsonencode(local.measurement_container_definitions)

  tags = {
    Name = local.measurement_family
  }

  # The log group exists before the task could log to it.
  depends_on = [aws_cloudwatch_log_group.measurement]

  lifecycle {
    precondition {
      condition     = join(",", sort([for container in local.measurement_production_containers : container.name])) == "api,valkey"
      error_message = "The production task definition no longer has exactly the api and valkey containers; review the measurement derivation before enabling the stack."
    }

    precondition {
      condition     = local.measurement_derived_api.image == local.measurement_production_api.image
      error_message = "The measurement API must run the production API image."
    }

    precondition {
      condition = (
        length(local.measurement_java_tool_options) == 1 &&
        endswith(one(local.measurement_java_tool_options), " ${local.measurement_gc_log_option}")
      )
      error_message = "The measurement API must carry exactly one JAVA_TOOL_OPTIONS, the production value followed by the GC logging option."
    }

    precondition {
      condition = alltrue([
        for container in local.measurement_container_definitions :
        container.logConfiguration.options["awslogs-group"] == local.measurement_log_group_name
      ])
      error_message = "Every measurement container must log to the measurement log group only."
    }
  }
}

# A DAEMON on the EC2 launch type, as in production: every host that registers
# with the measurement cluster runs one task, and no production host can,
# because production hosts register with the production cluster.
resource "aws_ecs_service" "measurement" {
  count = local.measurement_count

  name                          = local.measurement_service_name
  cluster                       = aws_ecs_cluster.measurement[0].id
  task_definition               = aws_ecs_task_definition.measurement[0].arn
  scheduling_strategy           = "DAEMON"
  launch_type                   = "EC2"
  enable_execute_command        = false
  availability_zone_rebalancing = "DISABLED"

  tags = {
    Name = local.measurement_service_name
  }

  depends_on = [aws_iam_role_policy.ecs_task_execution_measurement]
}

# The production launch template with three differences: the instance type is
# the measured one, the instance profile is the measurement profile, and the
# loader joins the measurement cluster, group and hook with no Elastic IP. The
# same AMI, bundle version, Spot market, standard credits, IMDSv2, encrypted
# root volume, public IPv4 and security group.
resource "aws_launch_template" "ecs_spot_measurement" {
  count = local.measurement_count

  name        = local.measurement_name
  description = "Phase 6C-5c ECS EC2 Spot host for the separate measurement cluster"

  image_id      = local.ecs_ami_id
  instance_type = local.measurement_instance_type

  instance_market_options {
    market_type = "spot"
  }

  credit_specification {
    cpu_credits = "standard"
  }

  iam_instance_profile {
    name = aws_iam_instance_profile.ecs_spot_measurement[0].name
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_type           = "gp3"
      volume_size           = 30
      encrypted             = "true"
      delete_on_termination = "true"
    }
  }

  # The production security group, referenced and not changed: the database
  # admits it, and its HTTPS ingress is CloudFront's origin-facing prefix list
  # only. No DNS name or Elastic IP points at a measurement host.
  network_interfaces {
    device_index                = 0
    associate_public_ip_address = "true"
    delete_on_termination       = "true"
    security_groups             = [aws_security_group.ec2_origin.id]
  }

  user_data = base64encode(local.measurement_user_data)

  tag_specifications {
    resource_type = "instance"

    tags = merge(local.common_tags, {
      Name = local.measurement_name
    })
  }

  tag_specifications {
    resource_type = "volume"

    tags = merge(local.common_tags, {
      Name = local.measurement_name
    })
  }

  tags = {
    Name = local.measurement_name
  }

  lifecycle {
    precondition {
      condition     = contains(local.measurement_allowed_instance_types, local.measurement_instance_type)
      error_message = "measurement_instance_type must be t3a.medium or t3a.small."
    }

    precondition {
      condition     = length(local.measurement_user_data_size_upper_bound) <= 16384
      error_message = "The rendered measurement loader exceeds the 16 KiB EC2 raw user-data limit."
    }

    # The measurement host must never move the origin Elastic IP: no allocation
    # in its loader at all, and the cluster, group and hook it reports to are
    # the measurement ones.
    precondition {
      condition = (
        !strcontains(local.measurement_user_data, "eipalloc-") &&
        strcontains(local.measurement_user_data, "readonly EIP_ALLOCATION_ID_VALUE=\"\"\n") &&
        strcontains(local.measurement_user_data, "readonly ECS_CLUSTER_NAME_VALUE=\"${local.measurement_cluster_name}\"\n") &&
        strcontains(local.measurement_user_data, "readonly AUTOSCALING_GROUP_NAME=\"${local.measurement_name}\"\n") &&
        strcontains(local.measurement_user_data, "readonly LIFECYCLE_HOOK_NAME=\"${local.measurement_lifecycle_hook_name}\"\n")
      )
      error_message = "The measurement loader must carry no Elastic IP allocation and must name the measurement cluster, group and hook."
    }
  }
}

resource "aws_autoscaling_group" "ecs_spot_measurement" {
  count = local.measurement_count

  name                = local.measurement_name
  vpc_zone_identifier = [aws_subnet.public_app.id]

  # One host at most, none until a run. The operator raises desired to 1 for a
  # run and back to 0 after it (update-auto-scaling-group --desired-capacity).
  # desired_capacity is managed here, not ignored, so a host left running shows
  # up in the next plan as a change back to 0.
  min_size         = 0
  desired_capacity = 0
  max_size         = 1

  # A rebalance recommendation must not start a second host in the middle of a
  # run: an interrupted run is invalid and is repeated, not replaced.
  capacity_rebalance = false

  health_check_type         = "EC2"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.ecs_spot_measurement[0].id
    version = tostring(aws_launch_template.ecs_spot_measurement[0].latest_version)
  }

  # No AmazonECSManaged tag: the measurement cluster has no capacity provider,
  # and the host registers by the ECS_CLUSTER its loader writes.
  tag {
    key                 = "Name"
    value               = local.measurement_name
    propagate_at_launch = true
  }

  dynamic "tag" {
    for_each = local.common_tags

    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }
}

# The production launch hook contract: the host is InService only after the
# bootstrap's post phase proved registration with the measurement cluster, API
# readiness (database and Valkey included) and the local HTTPS origin, and
# reported CONTINUE. ABANDON is the default. See compute_spot.tf for the sizing
# of the heartbeat.
resource "aws_autoscaling_lifecycle_hook" "ecs_spot_measurement_launching" {
  count = local.measurement_count

  name                   = local.measurement_lifecycle_hook_name
  autoscaling_group_name = aws_autoscaling_group.ecs_spot_measurement[0].name
  lifecycle_transition   = "autoscaling:EC2_INSTANCE_LAUNCHING"
  default_result         = "ABANDON"
  heartbeat_timeout      = 3600
}

# The cost backstop. Runs happen on weekdays between 12:05 and 16:30 JST, away
# from the certbot timer (02:00 and 14:00 UTC plus up to an hour) and inside the
# database's running hours. At minute 30 of every hour outside 12:00-16:00, any
# day, the group goes back to 0/0/1. A host left running ends at 16:30 at the
# latest when it was started inside the window, and within the hour when it
# was started outside it, weekends included.
#
# The action writes the group's own min and max, so it never shows as drift.
# It is an Auto Scaling scheduled action on this group only, not an EventBridge
# Scheduler schedule.
resource "aws_autoscaling_schedule" "ecs_spot_measurement_backstop" {
  count = local.measurement_count

  scheduled_action_name  = "${local.measurement_name}-backstop"
  autoscaling_group_name = aws_autoscaling_group.ecs_spot_measurement[0].name
  recurrence             = "30 0-11,16-23 * * *"
  time_zone              = "Asia/Tokyo"
  min_size               = 0
  max_size               = 1
  desired_capacity       = 0
}
