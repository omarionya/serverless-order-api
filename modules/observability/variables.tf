variable "name" {
  type = string
}
variable "api_name" {
  type = string
}
variable "stage_name" {
  type = string
}
variable "alarm_topic_arn" {
  type = string
}
variable "functions" {
  description = "All functions; failure_phrase catches logged failures returned as HTTP/partial-batch responses."
  type = map(object({
    name           = string
    log_group      = string
    timeout        = number
    failure_phrase = string
  }))
}
variable "publisher_function_name" {
  type = string
}
variable "queues" {
  description = "Logical queue name => actual queue name (dashboard only; existing consumer alarms are routed to SNS)."
  type        = map(string)
}
variable "tables" {
  type = map(string)
}
variable "api_latency_threshold_ms" {
  type    = number
  default = 1500
}
variable "stream_age_threshold_ms" {
  type    = number
  default = 60000
}
variable "tags" {
  type    = map(string)
  default = {}
}
