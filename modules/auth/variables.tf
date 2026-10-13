variable "name" {
  type = string
}

variable "domain_prefix" {
  description = "Unique prefix for the Cognito hosted domain."
  type        = string
}

variable "callback_urls" {
  description = "Allowed OAuth redirect URLs."
  type        = list(string)
}

variable "tags" {
  type    = map(string)
  default = {}
}