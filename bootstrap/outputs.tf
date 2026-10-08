output "state_bucket_name" {
  description = "Bucket name to use in Terraform backend configuration."
  value       = aws_s3_bucket.terraform_state.id
}

output "state_bucket_arn" {
  description = "Terraform state bucket ARN."
  value       = aws_s3_bucket.terraform_state.arn
}

output "aws_region" {
  description = "Region containing the state bucket."
  value       = var.aws_region
}

output "state_bucket_tags" {
  description = "All tags applied to the bucket."
  value       = aws_s3_bucket.terraform_state.tags_all
}