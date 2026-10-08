variable "function_name" {
  description = "Name of the Order API Lambda."
  type        = string
}

variable "orders_table_name" {
  description = "DynamoDB orders table name."
  type        = string
}

variable "orders_table_arn" {
  description = "DynamoDB orders table ARN."
  type        = string
}

variable "handler_file" {
  description = "Path to the Python handler file."
  type        = string
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days."
  type        = number
  default     = 14
}

variable "tags" {
  description = "Additional resource tags."
  type        = map(string)
  default     = {}
}