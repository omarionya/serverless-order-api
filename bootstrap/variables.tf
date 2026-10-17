variable "aws_region" {
  description = "AWS region for the state bucket."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name used in resource tags."
  type        = string
  default     = "order-api"
}

variable "environment" {
  description = "Environment associated with the bootstrap resources."
  type        = string
  default     = "dev"
}

variable "state_bucket_name" {
  description = "Globally unique S3 bucket name for Terraform state."
  type        = string
}

variable "tags" {
  description = "Additional resource tags."
  type        = map(string)
  default     = {}
}

