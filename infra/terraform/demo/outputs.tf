output "vpc_id" {
  description = "ID of the Demo VPC."
  value       = aws_vpc.demo.id
}

output "public_app_subnet_id" {
  description = "ID of the public subnet reserved for the future Demo EC2 origin."
  value       = aws_subnet.public_app.id
}

output "private_db_subnet_ids" {
  description = "IDs of the two private DB subnets, keyed by stable logical AZ slot."
  value = {
    for key, subnet in aws_subnet.private_db : key => subnet.id
  }
}

output "ec2_origin_security_group_id" {
  description = "ID of the future EC2 origin security group."
  value       = aws_security_group.ec2_origin.id
}

output "rds_security_group_id" {
  description = "ID of the private RDS security group."
  value       = aws_security_group.rds.id
}

output "cloudfront_origin_prefix_list_id" {
  description = "ID of the AWS-managed CloudFront origin-facing prefix list resolved in Tokyo."
  value       = data.aws_ec2_managed_prefix_list.cloudfront_origin_facing.id
}

output "public_app_route_table_id" {
  description = "ID of the public app route table."
  value       = aws_route_table.public_app.id
}

output "private_db_route_table_id" {
  description = "ID of the isolated private DB route table."
  value       = aws_route_table.private_db.id
}

output "ec2_instance_id" {
  description = "ID of the Demo EC2 instance."
  value       = aws_instance.demo.id
}

output "ec2_instance_profile_name" {
  description = "Name of the Demo EC2 instance profile."
  value       = aws_iam_instance_profile.ec2.name
}

output "ec2_eip_public_ip" {
  description = "Elastic IP reserved for the future CloudFront custom origin."
  value       = aws_eip.ec2_origin.public_ip
}

output "rds_identifier" {
  description = "Identifier of the Demo MariaDB instance."
  value       = aws_db_instance.demo.identifier
}

output "rds_address" {
  description = "Private DNS address of the Demo MariaDB instance."
  value       = aws_db_instance.demo.address
}

output "rds_port" {
  description = "Port of the Demo MariaDB instance."
  value       = aws_db_instance.demo.port
}

output "rds_db_name" {
  description = "Initial database name of the Demo MariaDB instance."
  value       = aws_db_instance.demo.db_name
}

output "db_password_parameter_name" {
  description = "Name of the SecureString that stores the Demo database master password."
  value       = aws_ssm_parameter.db_master_password.name
}

output "db_password_parameter_arn" {
  description = "ARN of the SecureString that stores the Demo database master password."
  value       = aws_ssm_parameter.db_master_password.arn
}

output "ecr_repository_name" {
  description = "Name of the private Demo API image repository."
  value       = aws_ecr_repository.demo_api.name
}

output "ecr_repository_url" {
  description = "URL of the private Demo API image repository."
  value       = aws_ecr_repository.demo_api.repository_url
}

output "jwt_secret_parameter_name" {
  description = "Name of the SecureString that stores the Demo application JWT signing secret."
  value       = aws_ssm_parameter.auth_jwt_secret.name
}

output "jwt_secret_parameter_arn" {
  description = "ARN of the SecureString that stores the Demo application JWT signing secret."
  value       = aws_ssm_parameter.auth_jwt_secret.arn
}

output "origin_hostname" {
  description = "Public DNS hostname reserved for the Demo EC2 HTTPS origin."
  value       = local.origin_hostname
}

output "origin_verify_parameter_name" {
  description = "Name of the SecureString reserved for the future CloudFront origin verification token."
  value       = aws_ssm_parameter.origin_verify_token.name
}

output "origin_verify_parameter_arn" {
  description = "ARN of the SecureString reserved for the future CloudFront origin verification token."
  value       = aws_ssm_parameter.origin_verify_token.arn
}

output "scheduler_group_name" {
  description = "Name of the EventBridge Scheduler group for Demo runtime lifecycle control."
  value       = aws_scheduler_schedule_group.runtime.name
}

output "scheduler_role_name" {
  description = "Name of the least-privilege EventBridge Scheduler execution role."
  value       = aws_iam_role.scheduler.name
}

output "schedule_names" {
  description = "Names of the four Demo runtime schedules, keyed by lifecycle operation."
  value = {
    for key, schedule in aws_scheduler_schedule.runtime : key => schedule.name
  }
}

output "scheduler_failure_alarm_name" {
  description = "Name of the group-level Scheduler final-failure alarm."
  value       = aws_cloudwatch_metric_alarm.scheduler_invocation_dropped.alarm_name
}

output "alert_topic_arn" {
  description = "ARN of the shared Scheduler and Budget alert topic."
  value       = aws_sns_topic.alerts.arn
}

output "budget_name" {
  description = "Name of the account-wide monthly Demo cost budget."
  value       = aws_budgets_budget.monthly_cost.name
}

output "cloudfront_distribution_id" {
  description = "ID of the Demo API CloudFront distribution."
  value       = aws_cloudfront_distribution.api.id
}

output "cloudfront_distribution_domain_name" {
  description = "Default CloudFront domain name for the Demo API."
  value       = aws_cloudfront_distribution.api.domain_name
}

output "store_s3_bucket_name" {
  description = "Private bucket for Store artifacts; Terraform does not upload files."
  value       = try(aws_s3_bucket.frontend["store"].id, null)
}

output "admin_s3_bucket_name" {
  description = "Private bucket for Admin artifacts; Terraform does not upload files."
  value       = try(aws_s3_bucket.frontend["admin"].id, null)
}

output "store_cloudfront_distribution_id" {
  description = "ID of the Store static distribution, separate from the API."
  value       = try(aws_cloudfront_distribution.frontend["store"].id, null)
}

output "store_cloudfront_domain_name" {
  description = "Default Store CloudFront domain."
  value       = try(aws_cloudfront_distribution.frontend["store"].domain_name, null)
}

output "admin_cloudfront_distribution_id" {
  description = "ID of the Admin static distribution, separate from the API."
  value       = try(aws_cloudfront_distribution.frontend["admin"].id, null)
}

output "admin_cloudfront_domain_name" {
  description = "Default Admin CloudFront domain."
  value       = try(aws_cloudfront_distribution.frontend["admin"].domain_name, null)
}

output "github_frontend_deploy_role_arn" {
  description = "ARN of the GitHub OIDC role restricted to Store and Admin artifact deployment."
  value       = aws_iam_role.github_frontend_deploy.arn
}

output "github_backend_deploy_role_arn" {
  description = "ARN of the GitHub OIDC role restricted to Demo API image publication."
  value       = aws_iam_role.github_backend_deploy.arn
}

output "deploy_desired_image_sha_parameter_name" {
  description = "Name of the non-secret parameter holding the API image SHA the host should converge to."
  value       = aws_ssm_parameter.deploy_desired_image_sha.name
}

output "deploy_last_known_good_image_sha_parameter_name" {
  description = "Name of the non-secret parameter holding the last API image SHA verified healthy."
  value       = aws_ssm_parameter.deploy_last_known_good_image_sha.name
}

output "deploy_pending_migration_image_sha_parameter_name" {
  description = "Name of the non-secret parameter holding an image SHA blocked by the Flyway migration gate."
  value       = aws_ssm_parameter.deploy_pending_migration_image_sha.name
}

output "runtime_db_host_parameter_name" {
  description = "Name of the non-secret parameter holding the Demo database endpoint."
  value       = aws_ssm_parameter.runtime_db_host.name
}

output "runtime_db_port_parameter_name" {
  description = "Name of the non-secret parameter holding the Demo database port."
  value       = aws_ssm_parameter.runtime_db_port.name
}

output "runtime_db_name_parameter_name" {
  description = "Name of the non-secret parameter holding the Demo database name."
  value       = aws_ssm_parameter.runtime_db_name.name
}

output "runtime_db_username_parameter_name" {
  description = "Name of the non-secret parameter holding the Demo database username."
  value       = aws_ssm_parameter.runtime_db_username.name
}

output "runtime_cors_allowed_origins_parameter_name" {
  description = "Name of the non-secret parameter holding the Phase 5C CORS allowlist."
  value       = aws_ssm_parameter.runtime_cors_allowed_origins.name
}

output "origin_tls_backup_bucket_name" {
  description = "Name of the private bucket holding the archived origin TLS state. Supply it to sync-origin-tls.sh as ORIGIN_TLS_BUCKET."
  value       = aws_s3_bucket.origin_tls.bucket
}

output "ecs_cluster_name" {
  description = "Name of the Demo ECS cluster. Supply it to bootstrap-spot-host.sh as ECS_CLUSTER_NAME."
  value       = aws_ecs_cluster.demo.name
}

output "ecs_cluster_arn" {
  description = "ARN of the Demo ECS cluster."
  value       = aws_ecs_cluster.demo.arn
}

output "ecs_spot_capacity_provider_name" {
  description = "Name of the Spot capacity provider the Phase 6C-4 ECS service must name explicitly."
  value       = aws_ecs_capacity_provider.ecs_spot.name
}

output "ecs_spot_launch_template_id" {
  description = "ID of the ECS EC2 Spot launch template."
  value       = aws_launch_template.ecs_spot.id
}

output "ecs_spot_launch_template_version" {
  description = "Launch template version the Auto Scaling group is pinned to. Not $Latest."
  value       = aws_launch_template.ecs_spot.latest_version
}

output "ecs_spot_autoscaling_group_name" {
  description = "Name of the ECS EC2 Spot Auto Scaling group. Created with desired capacity zero."
  value       = aws_autoscaling_group.ecs_spot.name
}

output "ecs_spot_autoscaling_group_arn" {
  description = "ARN of the ECS EC2 Spot Auto Scaling group."
  value       = aws_autoscaling_group.ecs_spot.arn
}

output "ecs_spot_lifecycle_hook_name" {
  description = "Name of the launch lifecycle hook a booting host completes with CONTINUE or ABANDON."
  value       = aws_autoscaling_lifecycle_hook.ecs_spot_launching.name
}

output "ecs_spot_instance_profile_name" {
  description = "Name of the ECS EC2 Spot instance profile, held separately from the On-Demand origin host profile."
  value       = aws_iam_instance_profile.ecs_spot.name
}

output "runtime_artifacts_bucket_name" {
  description = "Name of the private bucket holding the versioned Spot runtime bundle."
  value       = aws_s3_bucket.runtime_artifacts.bucket
}

output "spot_runtime_bundle_object_key" {
  description = "Stable object key of the Spot runtime bundle. Identity comes from the object version, not this key."
  value       = aws_s3_object.spot_runtime_bundle.key
}

output "spot_runtime_bundle_version_id" {
  description = "S3 object version the current launch template version pins. Do not expire this version while any launch template version references it."
  value       = aws_s3_object.spot_runtime_bundle.version_id
}

output "spot_runtime_bundle_sha256" {
  description = "SHA256 of the runtime bundle archive the loader verifies before executing anything from it."
  value       = data.archive_file.spot_runtime_bundle.output_sha256
}
