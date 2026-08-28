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
