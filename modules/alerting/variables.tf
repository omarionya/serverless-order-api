variable "name" {
  type = string
}
variable "alert_emails" {
  description = "Email subscriptions; recipients must confirm the SNS subscription."
  type        = set(string)
  default     = []
}
variable "failed_batches_bucket_name" {
  type = string
}
variable "tags" {
  type    = map(string)
  default = {}
}
