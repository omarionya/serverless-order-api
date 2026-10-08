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
