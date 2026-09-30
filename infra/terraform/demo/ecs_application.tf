# Phase 6C-4: the ECS application layer on the Spot capacity.
#
# One task per Spot host: the API and its Valkey, side by side on the host
# network. The service is a DAEMON on the EC2 launch type, so every container
# instance that registers with the cluster runs exactly one task. That is what
# bootstrap-spot-host.sh post waits for on each new host -- agent registration,
# then API readiness on 127.0.0.1:8080, then the origin, then CONTINUE -- and a
# REPLICA service would leave a second host (capacity rebalance, max 2) without
# a task and abandoning in a loop.
#
# The names below are fixed by the Access IaC (Phase 6C-4 ECS application
# permissions in infra/terraform/access/README.md): the Apply and Plan
# permission sets name these exact ARNs. A different name fails closed with an
# AccessDenied rather than widening anything.
#
# While the Auto Scaling group stays at desired 0 this starts no task and no
# instance: a DAEMON service with no container instance places nothing.

locals {
  ecs_api_log_group_name       = "/ec-portfolio/demo/ecs/api"
  ecs_task_execution_role_name = "${local.name_prefix}-ecs-task-execution"
  ecs_api_family               = "${local.name_prefix}-api"
  ecs_api_service_name         = "${local.name_prefix}-api"

  # The On-Demand host's last-known-good release, pinned here rather than read
  # from the CI-owned /ec-portfolio/demo/deploy/* parameters. Flyway migrates the
  # shared RDS at API startup, so a Spot task must run exactly the release the
  # On-Demand host runs; a data source would let a CI publish change what a new
  # Spot host starts without any plan showing it. A full Git SHA in an
  # IMMUTABLE repository, never a moving tag. Changing it is an explicit PR.
  ecs_api_image_sha = "868efcc04316de89e73174c48d42619cd4466a14"

  # The image the standalone host runs (deploy-api.sh VALKEY_IMAGE,
  # valkey/valkey:8.1.9-alpine), pinned to the linux/amd64 manifest that was
  # inspected below. A tag is resolved only when the first task starts, which
  # with the Auto Scaling group at 0 is some unknown time after this apply; the
  # digest makes the image that runs the one whose user, layers and /data
  # ownership were checked.
  ecs_valkey_image = "valkey/valkey@sha256:16625369f78a3844287f298799bebb7f4e59d0f7f40e789779d60e890f3d4399"

  # Both containers run as their image's own non-root user, named numerically
  # so a missing passwd entry cannot turn into root.
  #
  #   API     apps/api/Dockerfile: USER 10001:10001.
  #   Valkey  valkey/valkey:8.1.9-alpine (linux/amd64 manifest
  #           sha256:16625369f78a3844287f298799bebb7f4e59d0f7f40e789779d60e890f3d4399)
  #           runs `addgroup -S -g 1000 valkey; adduser -S -G valkey -u 999
  #           valkey`, and its /etc/passwd reads valkey:x:999:1000. Its
  #           entrypoint only drops privileges when started as root, and /data
  #           is 999:1000 with mode 1777, so starting as 999:1000 is supported.
  #
  # The UIDs also matter to the IMDS guard: imds-guard.sh lets UID 0 reach IMDS
  # and rejects every other UID, so neither container can read the instance
  # role's credentials.
  ecs_api_user    = "10001:10001"
  ecs_valkey_user = "999:1000"

  # The standalone host's runtime environment (deploy-api.sh), derived from the
  # same resources runtime_parameters.tf publishes it from, plus the settings
  # host networking needs: the API binds IPv4 loopback only, and reaches Valkey
  # on loopback rather than through a Docker network alias.
  #
  # origin-smoke-check-ecs.sh requires exactly one IPv4 listener on
  # 127.0.0.1:8080 and on 127.0.0.1:6379, and no IPv6 listener on either.
  # SERVER_ADDRESS binds Spring Boot's only listener (actuator shares
  # server.port); preferIPv4Stack keeps the JVM from opening an IPv6 socket.
  ecs_api_environment = {
    APP_CORS_ALLOWED_ORIGINS = join(",", local.runtime_cors_allowed_origins)
    APP_OPENAPI_ENABLED      = "false"
    DB_HOST                  = aws_db_instance.demo.address
    DB_NAME                  = aws_db_instance.demo.db_name
    DB_PORT                  = tostring(aws_db_instance.demo.port)
    DB_USERNAME              = aws_db_instance.demo.username
    JAVA_TOOL_OPTIONS        = "-Djava.net.preferIPv4Stack=true"
    REDIS_HOST               = "127.0.0.1"
    REDIS_PORT               = "6379"
    SERVER_ADDRESS           = "127.0.0.1"
    SPRING_PROFILES_ACTIVE   = "demo"
  }

  # Secrets are references, never values: the task definition and the state
  # hold the parameter ARNs, and the ECS agent reads the values with the task
  # execution role when it starts the container.
  ecs_api_secrets = {
    APP_AUTH_JWT_SECRET = aws_ssm_parameter.auth_jwt_secret.arn
    DB_PASSWORD         = aws_ssm_parameter.db_master_password.arn
  }
}

resource "aws_cloudwatch_log_group" "ecs_api" {
  name              = local.ecs_api_log_group_name
  retention_in_days = 7

  tags = {
    Name = "${local.name_prefix}-ecs-api"
  }
}

# The identity the ECS agent uses to start the task: pull the image, read the
# two secrets, write the task's logs. No task role: the API makes no AWS call.
#
# The AWS-managed AmazonECSTaskExecutionRolePolicy is deliberately not
# attached. It grants ECR pulls from every repository and log writes to every
# log group on "*". The three policies below are the same agent contract with
# the repository, the parameters and the log group named, and are the
# documents reviewed in the Access IaC README (Task execution role).
resource "aws_iam_role" "ecs_task_execution" {
  name        = local.ecs_task_execution_role_name
  description = "Demo ECS task execution role: API image pull, runtime secrets and task logs"

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
    Name = local.ecs_task_execution_role_name
  }
}

resource "aws_iam_role_policy" "ecs_task_execution_ecr_pull" {
  name = "ecr-image-pull"
  role = aws_iam_role.ecs_task_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # No resource type in the service reference, so "*" is the only form.
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

# ssm:GetParameters is the action the agent calls for task secrets. No
# kms:Decrypt: both parameters use the AWS managed key alias/aws/ssm, and the
# ECS guide requires kms:Decrypt only for a customer managed key.
resource "aws_iam_role_policy" "ecs_task_execution_runtime_secrets" {
  name = "runtime-secrets-read"
  role = aws_iam_role.ecs_task_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadApiRuntimeSecrets"
        Effect = "Allow"
        Action = "ssm:GetParameters"
        Resource = [
          aws_ssm_parameter.db_master_password.arn,
          aws_ssm_parameter.auth_jwt_secret.arn,
        ]
      },
    ]
  })
}

# The log group itself is Terraform's; the agent only creates the task's
# streams in it and writes to them.
resource "aws_iam_role_policy" "ecs_task_execution_logs" {
  name = "api-task-logs-write"
  role = aws_iam_role.ecs_task_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "WriteApiTaskLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "${aws_cloudwatch_log_group.ecs_api.arn}:log-stream:*"
      },
    ]
  })
}

# Host networking, as the standalone host's loopback contract requires: the
# origin's Nginx on the same host proxies to 127.0.0.1:8080, and nothing binds
# a routable address. The port mappings only reserve the two ports on the
# instance; the loopback binding is the containers' own configuration below.
#
# Valkey starts first and the API only once Valkey answers PING, so the API's
# readiness (which includes redis) is the one signal the bootstrap waits for.
# Both are essential: a task missing either is not a serving task.
#
# no-new-privileges matches the standalone host's --security-opt; no container
# is privileged, and none runs as root.
resource "aws_ecs_task_definition" "api" {
  family                   = local.ecs_api_family
  network_mode             = "host"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn

  container_definitions = jsonencode([
    {
      name                  = "valkey"
      image                 = local.ecs_valkey_image
      essential             = true
      user                  = local.ecs_valkey_user
      privileged            = false
      dockerSecurityOptions = ["no-new-privileges"]
      memoryReservation     = 128

      # Loopback IPv4 only (no "-::1", so no IPv6 listener) and nothing
      # persisted, as on the standalone host.
      command = [
        "valkey-server",
        "--bind", "127.0.0.1",
        "--port", "6379",
        "--protected-mode", "yes",
        "--save", "",
        "--appendonly", "no",
      ]

      portMappings = [
        {
          containerPort = 6379
          hostPort      = 6379
          protocol      = "tcp"
        },
      ]

      # The standalone host's health check, pointed at the loopback address
      # the server binds.
      healthCheck = {
        command     = ["CMD", "valkey-cli", "-h", "127.0.0.1", "-p", "6379", "ping"]
        interval    = 10
        timeout     = 3
        retries     = 5
        startPeriod = 5
      }

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.ecs_api.name
          awslogs-region        = local.aws_region
          awslogs-stream-prefix = "valkey"
        }
      }
    },
    {
      name                  = "api"
      image                 = "${aws_ecr_repository.demo_api.repository_url}:${local.ecs_api_image_sha}"
      essential             = true
      user                  = local.ecs_api_user
      privileged            = false
      dockerSecurityOptions = ["no-new-privileges"]
      memoryReservation     = 1024

      # The standalone host's API_STOP_GRACE_SECONDS.
      stopTimeout = 30

      environment = [
        for name in sort(keys(local.ecs_api_environment)) : {
          name  = name
          value = local.ecs_api_environment[name]
        }
      ]

      secrets = [
        for name in sort(keys(local.ecs_api_secrets)) : {
          name      = name
          valueFrom = local.ecs_api_secrets[name]
        }
      ]

      portMappings = [
        {
          containerPort = 8080
          hostPort      = 8080
          protocol      = "tcp"
        },
      ]

      dependsOn = [
        {
          containerName = "valkey"
          condition     = "HEALTHY"
        },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.ecs_api.name
          awslogs-region        = local.aws_region
          awslogs-stream-prefix = "api"
        }
      }
    },
  ])

  tags = {
    Name = local.ecs_api_family
  }
}

# DAEMON on the EC2 launch type. AWS accepts either a launch type or a capacity
# provider strategy, not both; with the launch type, the Spot capacity provider
# still supplies every container instance, because it is the only source of
# instances in this cluster. No desired count (a DAEMON has none), no load
# balancer, no service connect, no execute command, and no wait for steady
# state: with the Auto Scaling group at 0 there is nothing to wait for, and an
# apply must not block on host launches.
#
# The role policies are dependencies so the role can do its job before any
# task could be placed.
resource "aws_ecs_service" "api" {
  name                          = local.ecs_api_service_name
  cluster                       = aws_ecs_cluster.demo.id
  task_definition               = aws_ecs_task_definition.api.arn
  scheduling_strategy           = "DAEMON"
  launch_type                   = "EC2"
  enable_execute_command        = false
  availability_zone_rebalancing = "DISABLED"

  tags = {
    Name = local.ecs_api_service_name
  }

  depends_on = [
    aws_iam_role_policy.ecs_task_execution_ecr_pull,
    aws_iam_role_policy.ecs_task_execution_runtime_secrets,
    aws_iam_role_policy.ecs_task_execution_logs,
  ]
}
