variable "api_name" {
  type = string
}

variable "stage_name" {
  type = string
}

variable "lambda_function_name" {
  type = string
}

variable "lambda_invoke_arn" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "cognito_user_pool_arn" {
  description = "Cognito user pool used to authorize API requests."
  type        = string
}

variable "api_access_log_group_arn" {
  type = string
}
variable "manage_apigateway_logging_account" {
  description = "Manage the account/region-wide API Gateway logging role. Enable only if this root owns it."
  type        = bool
  default     = false
}