variable "name" {
  description = "Prefix for the Order Processor resources."
  type        = string
}
variable "event_bus_name" {
  type = string
}
variable "orders_table_name" {
  type = string
}
variable "orders_table_arn" {
  type = string
}
variable "handler_file" {
  type = string
}
variable "maximum_concurrency" {
  description = "Maximum concurrent SQS-triggered processor invocations."
  type        = number
  default     = 2
  validation {
    condition     = var.maximum_concurrency >= 2 && var.maximum_concurrency <= 1000 && floor(var.maximum_concurrency) == var.maximum_concurrency
    error_message = "Use an integer from 2 to 1000, within your AWS concurrency quota."
  }
}
variable "max_receive_count" {
  description = "Failed message receives before SQS moves it to the processing DLQ."
  type        = number
  default     = 5
  validation {
    condition     = var.max_receive_count >= 1 && floor(var.max_receive_count) == var.max_receive_count
    error_message = "Use a positive integer."
  }
}
variable "log_retention_days" {
  type    = number
  default = 14
}
variable "alarm_actions" {
  description = "Optional existing SNS topic ARNs for alarm notifications. Empty by default."
  type        = list(string)
  default     = []
}
variable "tags" {
  type    = map(string)
  default = {}
}
