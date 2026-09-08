locals {
  deploy_state_prefix        = "/ec-portfolio/demo/deploy"
  deploy_image_sha_pattern   = "^[0-9a-f]{40}$"
  deploy_pending_sha_pattern = "^([0-9a-f]{40}|none)$"

  # Git SHA of the API image the Demo host is verified to be running today. It
  # seeds both convergence parameters exactly once; GitHub Actions owns the
  # values afterwards, so Terraform ignores later drift.
  deploy_verified_image_sha = "799fddbfa5ed7f663182347f6291163fc4f57983"
}

resource "aws_ssm_parameter" "deploy_desired_image_sha" {
  name            = "${local.deploy_state_prefix}/desired-image-sha"
  description     = "Git SHA tag of the API image the Demo host should converge to. Not a secret."
  type            = "String"
  tier            = "Standard"
  allowed_pattern = local.deploy_image_sha_pattern
  value           = local.deploy_verified_image_sha

  lifecycle {
    ignore_changes = [value]
  }

  tags = {
    Name = "${local.name_prefix}-deploy-desired-image-sha"
  }
}

resource "aws_ssm_parameter" "deploy_last_known_good_image_sha" {
  name            = "${local.deploy_state_prefix}/last-known-good-image-sha"
  description     = "Git SHA tag of the last API image verified healthy on the Demo host. Not a secret."
  type            = "String"
  tier            = "Standard"
  allowed_pattern = local.deploy_image_sha_pattern
  value           = local.deploy_verified_image_sha

  lifecycle {
    ignore_changes = [value]
  }

  tags = {
    Name = "${local.name_prefix}-deploy-last-known-good-image-sha"
  }
}

resource "aws_ssm_parameter" "deploy_pending_migration_image_sha" {
  name            = "${local.deploy_state_prefix}/pending-migration-image-sha"
  description     = "Git SHA tag blocked by the Flyway migration gate and awaiting a manual release, or none."
  type            = "String"
  tier            = "Standard"
  allowed_pattern = local.deploy_pending_sha_pattern
  value           = "none"

  lifecycle {
    ignore_changes = [value]
  }

  tags = {
    Name = "${local.name_prefix}-deploy-pending-migration-image-sha"
  }
}
