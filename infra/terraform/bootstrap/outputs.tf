output "state_bucket_name" {
  description = "Name of the dedicated Terraform state bucket."
  value       = aws_s3_bucket.terraform_state.id
}

output "state_bucket_arn" {
  description = "ARN of the dedicated Terraform state bucket."
  value       = aws_s3_bucket.terraform_state.arn
}
