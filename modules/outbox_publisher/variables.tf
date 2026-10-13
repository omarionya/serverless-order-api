variable "function_name" {
  type = string
}
variable "outbox_stream_arn" {
  type = string
}
variable "event_bus_arn" {
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
