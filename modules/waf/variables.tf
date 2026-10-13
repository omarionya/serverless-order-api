variable "name" {
  type = string
}

variable "api_stage_arn" {
  description = "REST API stage ARN to protect."
  type        = string
}

variable "rate_limit" {
  description = "Per-IP request threshold over a five-minute window."
  type        = number
  default     = 2000
}

variable "tags" {
  type    = map(string)
  default = {}
}