variable "function_name" {
  type = string
}
variable "orders_table_name" {
  type = string
}
variable "orders_table_arn" {
  type = string
}
variable "idempotency_table_name" {
  type = string
}
variable "idempotency_table_arn" {
  type = string
}
variable "outbox_table_name" {
  type = string
}
variable "outbox_table_arn" {
  type = string
}
variable "handler_file" {
  type = string
}
variable "log_retention_days" {
  type    = number
  default = 14
}
variable "tags" {
  type    = map(string)
  default = {}
}
