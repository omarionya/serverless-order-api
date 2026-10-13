variable "name" {
  type = string
}
variable "notifications_table_name" {
  type = string
}
variable "notifications_table_arn" {
  type = string
}
variable "cognito_user_pool_id" {
  type = string
}
variable "cognito_user_pool_arn" {
  type = string
}
variable "ses_sender_email" {
  description = "Verified SES sender address, in the same region."
  type        = string
}
variable "ses_identity_arn" {
  description = "Existing verified SES email/domain identity ARN."
  type        = string
}
variable "handler_file" {
  type = string
}
variable "batch_limit" {
  description = "Pending emails attempted per minute. Keep 1 for initial sandbox testing."
  type        = number
  default     = 1
  validation {
    condition     = var.batch_limit >= 1 && var.batch_limit <= 10 && floor(var.batch_limit) == var.batch_limit
    error_message = "Use an integer from 1 to 10."
  }
}
variable "alarm_actions" {
  type    = list(string)
  default = []
}
variable "tags" {
  type    = map(string)
  default = {}
}
