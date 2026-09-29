# Phase 6C-3: the launch template, Auto Scaling group and launch lifecycle hook
# for ECS EC2 Spot hosts.
#
# The group is created empty. Its desired capacity stays at zero until Phase
# 6C-4 gives the cluster something to run, so this phase adds capacity that can
# be created without creating any.

locals {
  spot_user_data_template = "${path.module}/templates/ecs-spot-user-data.sh.tftpl"

  spot_user_data_variables = {
    aws_region                = local.aws_region
    runtime_bucket            = aws_s3_bucket.runtime_artifacts.bucket
    runtime_object_key        = local.spot_runtime_object_key
    runtime_object_version_id = aws_s3_object.spot_runtime_bundle.version_id
    runtime_archive_sha256    = data.archive_file.spot_runtime_bundle.output_sha256
    runtime_directory         = local.spot_runtime_host_directory
    archive_path              = local.spot_runtime_archive_host_path
    ecs_cluster_name          = aws_ecs_cluster.demo.name
    origin_tls_bucket         = aws_s3_bucket.origin_tls.bucket
    autoscaling_group_name    = local.ecs_spot_name
    lifecycle_hook_name       = local.ecs_spot_lifecycle_hook_name
  }

  spot_user_data = templatefile(local.spot_user_data_template, local.spot_user_data_variables)

  # EC2 rejects user data larger than 16 KiB in raw form. Two of the values
  # above are not known until apply -- the generated bucket name and the S3
  # version ID -- so measuring the rendered loader would defer the check to
  # apply time. Rendering it once more with those two replaced by placeholders
  # at their documented maxima (63 bytes for a bucket name, 1024 for a version
  # ID) gives an upper bound that is known during plan. If the bound fits, the
  # real loader fits.
  spot_user_data_size_upper_bound = templatefile(
    local.spot_user_data_template,
    merge(local.spot_user_data_variables, {
      runtime_bucket            = format("%063d", 0)
      runtime_object_version_id = format("%01024d", 0)
    }),
  )
}

resource "aws_launch_template" "ecs_spot" {
  name        = local.ecs_spot_name
  description = "Phase 6C-3 ECS EC2 Spot host for the Demo origin"

  image_id = local.ecs_ami_id

  # One instance type, matching the On-Demand origin host this will eventually
  # replace. A MixedInstancesPolicy would widen the Spot pools the group can
  # draw from, but the public app subnet is a single Availability Zone, which
  # removes half of what that buys, and no second type has been reviewed yet.
  instance_type = "t3a.medium"

  # The whole point of Phase 6C. Without this block the Auto Scaling group
  # launches On-Demand instances at On-Demand prices.
  instance_market_options {
    market_type = "spot"
  }

  # No max price is set, so the Spot price is capped at the On-Demand rate.
  # A lower cap would trade availability for a saving that Spot already gives.

  # T instances default to unlimited, which bills for sustained CPU above the
  # baseline. The On-Demand host runs standard; matching it keeps a burst from
  # turning into an unexpected line item.
  credit_specification {
    cpu_credits = "standard"
  }

  iam_instance_profile {
    name = aws_iam_instance_profile.ecs_spot.name
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  # 30 GiB is the size of the pinned AMI's root snapshot, not a preference: a
  # block device mapping cannot request a volume smaller than the snapshot it
  # restores. device_name matches the image's RootDeviceName -- a different
  # name would attach a second volume and leave the root at its default size.
  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_type           = "gp3"
      volume_size           = 30
      encrypted             = "true"
      delete_on_termination = "true"
    }
  }

  # The public app subnet does not assign public IPv4 on launch, and there is
  # no NAT gateway, so a host without a public address cannot reach S3, ECR,
  # Systems Manager or the package repositories. The subnet itself is left to
  # the Auto Scaling group: putting it here would pin the launch template to
  # one subnet and take the choice away from the group.
  network_interfaces {
    device_index                = 0
    associate_public_ip_address = "true"
    delete_on_termination       = "true"
    security_groups             = [aws_security_group.ec2_origin.id]
  }

  user_data = base64encode(local.spot_user_data)

  # Volumes can only be tagged from here: an Auto Scaling group's
  # propagate_at_launch reaches instances, not the volumes created with them.
  # The instance tags overlap with the group's propagated tags by design, with
  # identical values, so neither source has to be read to know what an instance
  # carries.
  tag_specifications {
    resource_type = "instance"

    tags = merge(local.common_tags, {
      Name = local.ecs_spot_name
    })
  }

  tag_specifications {
    resource_type = "volume"

    tags = merge(local.common_tags, {
      Name = local.ecs_spot_name
    })
  }

  tags = {
    Name = local.ecs_spot_name
  }

  lifecycle {
    precondition {
      condition     = length(local.spot_user_data_size_upper_bound) <= 16384
      error_message = "The rendered ECS Spot loader exceeds the 16 KiB EC2 raw user-data limit. Move logic into the runtime bundle rather than growing this template."
    }
  }
}

resource "aws_autoscaling_group" "ecs_spot" {
  name                = local.ecs_spot_name
  vpc_zone_identifier = [aws_subnet.public_app.id]

  # Created empty. Phase 6C-4 has no task definition yet, so a host that
  # launched now would build itself, wait for an API task that can never be
  # placed, fail its readiness gate and abandon itself. Zero is what keeps this
  # phase free of running instances and of cost.
  min_size         = 0
  desired_capacity = 0
  max_size         = 2

  # desired_capacity is deliberately NOT in an ignore_changes list. Until the
  # Phase 6C-5 scheduler owns this value, Terraform managing it is the only
  # thing that makes an out-of-band change to it visible in a plan. The
  # ignore_changes comes with the cutover, not before it.

  # Replaces a Spot host that has received a rebalance recommendation before it
  # is interrupted, rather than waiting for the two-minute notice.
  capacity_rebalance = true

  # EC2 status checks only. There is no load balancer to ask, and application
  # health is proven by the bootstrap before the launch hook is completed.
  health_check_type = "EC2"

  # The grace period starts when an instance reaches InService, which for this
  # group is after the launch hook has been completed with CONTINUE -- so by
  # then the host has already restored its TLS state, joined the cluster and
  # passed an HTTPS smoke check. This window therefore only has to cover EC2
  # status checks settling, not the bootstrap; the hook's heartbeat covers
  # that. The provider default is the same 300 seconds, stated here so the
  # separation from the heartbeat is visible.
  health_check_grace_period = 300

  # A concrete version number, never "$Latest". "$Latest" is a moving pointer
  # evaluated by AWS at launch time, which means a launch template edit changes
  # what the group launches without any plan showing it. Referencing
  # latest_version stores the number in the group, so a template change is an
  # Auto Scaling group change too.
  launch_template {
    id      = aws_launch_template.ecs_spot.id
    version = tostring(aws_launch_template.ecs_spot.latest_version)
  }

  # Required, not cosmetic. ECS adds this tag to a group when a capacity
  # provider is associated with it, and uses it on the instance to decide which
  # capacity provider a container instance belongs to. Declaring it here stops
  # Terraform removing it on the next plan, and propagate_at_launch is what
  # gets it onto the instances.
  tag {
    key                 = "AmazonECSManaged"
    value               = "true"
    propagate_at_launch = true
  }

  tag {
    key                 = "Name"
    value               = local.ecs_spot_name
    propagate_at_launch = true
  }

  # aws_autoscaling_group has no tags argument, so the provider's default_tags
  # never reach it or the instances it launches. The common tags are applied
  # here explicitly for both.
  dynamic "tag" {
    for_each = local.common_tags

    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }
}

# The gate that makes a failed bootstrap a replaced host rather than a host
# that sits there registered to nothing.
#
# bootstrap-spot-host.sh already keeps a half-built host out of the cluster: it
# holds the ECS agent back and disables it again on any failure. What it cannot
# do is make the Auto Scaling group notice. An EC2 health check will not,
# because the operating system is perfectly healthy on a host whose TLS restore
# failed. So the instance is held in Pending:Wait while the bootstrap runs.
#
# Since Phase 6C-4a the outcome has two reporters, one at a time. The loader
# runs the bootstrap's pre phase inside user data and reports ABANDON if it
# fails. When it succeeds the pre phase has queued
# ec-portfolio-spot-post-bootstrap.service, which runs after cloud-final and
# ecs.service, proves the host and reports CONTINUE -- or ABANDON on any failure
# or on its own start timeout. Nothing in user data waits for the ECS agent.
#
# ABANDON is the default result rather than CONTINUE because the failure this
# has to survive is the one where nothing reports at all -- a loader that died
# before it read its own instance ID, or a host that never ran user data. Those
# must not become InService by timing out.
#
# 3600 seconds is sized from the configured bounds rather than measured:
#   - pre phase, worst case about 12 minutes: the ten-minute certbot install
#     budget plus the bundle download, the TLS restore, the IMDS guard and the
#     30-second systemctl calls;
#   - post phase, bounded by the unit's TimeoutStartSec of 30 minutes plus a
#     2-minute TimeoutStopSec in which the script reports ABANDON.
# That is about 44 minutes at worst, inside the hour with room to spare. The
# 6C-3 value of 1800 did not cover it: registration, readiness, the Nginx
# install and the smoke alone could use most of it. A host that never reports
# waits the full hour before its ABANDON default applies, at Spot cost.
#

# No notification_target_arn or role_arn: Auto Scaling publishes lifecycle
# events to EventBridge regardless, and nothing here consumes them yet.
resource "aws_autoscaling_lifecycle_hook" "ecs_spot_launching" {
  name                   = local.ecs_spot_lifecycle_hook_name
  autoscaling_group_name = aws_autoscaling_group.ecs_spot.name
  lifecycle_transition   = "autoscaling:EC2_INSTANCE_LAUNCHING"
  default_result         = "ABANDON"
  heartbeat_timeout      = 3600
}
