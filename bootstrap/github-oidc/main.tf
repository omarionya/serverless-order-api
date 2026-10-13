terraform {
  required_version = ">= 1.10, < 2.0"
  backend "s3" {}
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}
provider "aws" {
  region = var.aws_region
  default_tags { tags = var.tags }
}
variable "aws_region" { type = string }
variable "github_repository" {
  description = "Exact, case-sensitive OWNER/REPOSITORY"
  type        = string
}
variable "existing_oidc_provider_arn" {
  description = "Reuse an account's existing GitHub OIDC provider; empty creates one."
  type        = string
  default     = ""
}
variable "state_bucket" { type = string }
variable "state_key" {
  type    = string
  default = "order-api/dev/terraform.tfstate"
}
variable "resource_prefix" {
  type    = string
  default = "order-api-dev"
}
variable "tags" {
  type    = map(string)
  default = { Project = "order-api", Environment = "dev", ManagedBy = "Terraform" }
}

variable "github_owner_id" {
  description = "Numeric GitHub owner ID."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.github_owner_id))
    error_message = "GitHub owner ID must contain only digits."
  }
}

variable "github_repository_id" {
  description = "Numeric GitHub repository ID."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.github_repository_id))
    error_message = "GitHub repository ID must contain only digits."
  }
}
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
locals {
  account           = data.aws_caller_identity.current.account_id
  partition         = data.aws_partition.current.partition
  provider_arn      = var.existing_oidc_provider_arn != "" ? var.existing_oidc_provider_arn : aws_iam_openid_connect_provider.github[0].arn
  github_owner_name = split("/", var.github_repository)[0]
  github_repo_name  = split("/", var.github_repository)[1]

  github_oidc_subject = format(
    "repo:%s@%s/%s@%s:environment:dev",
    local.github_owner_name,
    var.github_owner_id,
    local.github_repo_name,
    var.github_repository_id
  )


}
resource "aws_iam_openid_connect_provider" "github" {
  count          = var.existing_oidc_provider_arn == "" ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}
resource "aws_iam_role" "deploy" {
  name                 = "github-${var.resource_prefix}-deploy"
  max_session_duration = 3600
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = local.github_oidc_subject
        }
      }
    }]
  })
}
# Development account policy: service-wide infrastructure authority, not a
# production least-privilege policy. IAM writes are restricted to project names.
resource "aws_iam_role_policy" "deploy" {
  name = "deploy-dev-infrastructure"
  role = aws_iam_role.deploy.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DevInfrastructureServices"
        Effect   = "Allow"
        Action   = ["lambda:*", "dynamodb:*", "events:*", "sqs:*", "sns:*", "logs:*", "cloudwatch:*", "apigateway:*", "cognito-idp:*", "wafv2:*", "scheduler:*", "xray:*", "ses:Get*", "ses:List*", "tag:GetResources"]
        Resource = "*"
      },
      {
        Sid      = "ProjectRolesAndPolicies"
        Effect   = "Allow"
        Action   = ["iam:GetRole", "iam:CreateRole", "iam:DeleteRole", "iam:UpdateRole", "iam:UpdateRoleDescription", "iam:UpdateAssumeRolePolicy", "iam:TagRole", "iam:UntagRole", "iam:ListRoleTags", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:GetRolePolicy", "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:GetPolicy", "iam:GetPolicyVersion", "iam:CreatePolicy", "iam:DeletePolicy", "iam:CreatePolicyVersion", "iam:DeletePolicyVersion", "iam:ListPolicyVersions", "iam:TagPolicy", "iam:UntagPolicy", "iam:ListPolicyTags"]
        Resource = ["arn:${local.partition}:iam::${local.account}:role/${var.resource_prefix}*", "arn:${local.partition}:iam::${local.account}:policy/${var.resource_prefix}*"]
      },
      {
        Sid       = "PassProjectServiceRoles"
        Effect    = "Allow"
        Action    = "iam:PassRole"
        Resource  = "arn:${local.partition}:iam::${local.account}:role/${var.resource_prefix}*"
        Condition = { StringEquals = { "iam:PassedToService" = ["lambda.amazonaws.com", "apigateway.amazonaws.com", "scheduler.amazonaws.com", "events.amazonaws.com"] } }
      },
      {
        Sid      = "ReadAWSManagedPolicy"
        Effect   = "Allow"
        Action   = ["iam:GetPolicy", "iam:GetPolicyVersion"]
        Resource = "arn:${local.partition}:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
      },
      {
        Sid    = "PublisherFailureBuckets"
        Effect = "Allow"
        Action = "s3:*"
        Resource = [
          "arn:${local.partition}:s3:::order-outbox-failures-d3356246b5e9eba7673cf0777c",
          "arn:${local.partition}:s3:::order-outbox-failures-d3356246b5e9eba7673cf0777c/*"
        ]
      },
      {
        Sid      = "StateBucketList"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = "arn:${local.partition}:s3:::${var.state_bucket}"
      },
      {
        Sid      = "DevState"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = "arn:${local.partition}:s3:::${var.state_bucket}/${var.state_key}"
      },
      {
        Sid      = "DevStateLock"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "arn:${local.partition}:s3:::${var.state_bucket}/${var.state_key}.tflock"
      }
    ]
  })
}
output "github_deploy_role_arn" { value = aws_iam_role.deploy.arn }
