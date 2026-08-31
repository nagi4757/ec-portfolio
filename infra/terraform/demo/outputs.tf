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
