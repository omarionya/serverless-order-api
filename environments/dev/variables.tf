variable "aws_region" {
  type = string
}

variable "project" {
  type = string
}

variable "environment" {
  type = string
}
variable "tags" {
  type    = map(string)
  default = {}
}
variable "cognito_domain_prefix" {
  description = "Unique Cognito domain prefix."
  type        = string
}

variable "oauth_callback_urls" {
  type = list(string)

  default = [
    "https://oauth.pstmn.io/v1/callback"
  ]
}

variable "enable_email_delivery" {
  description = "Enable SES delivery of pending notification requests."
  type        = bool
  default     = false
}
variable "ses_sender_email" {
  description = "Existing verified SES sender address."
  type        = string
  default     = ""
}
variable "ses_identity_arn" {
  description = "Existing verified SES sender email/domain identity ARN."
  type        = string
  default     = ""
}

variable "alert_emails" {
  description = "SNS alarm recipients; confirm the subscription email before testing."
  type        = set(string)
  default     = []
}
variable "manage_apigateway_logging_account" {
  description = "Enable only if this root owns the regional API Gateway logging account setting."
  type        = bool
  default     = false
}