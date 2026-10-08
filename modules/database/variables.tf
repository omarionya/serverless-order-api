variable "table_name" {
  description = "Name of the DynamoDB orders table."
  type        = string
}

variable "billing_mode" {
  description = "DynamoDB billing mode."
  type        = string
  default     = "PAY_PER_REQUEST"

  validation {
    condition = contains(
      ["PAY_PER_REQUEST", "PROVISIONED"],
      var.billing_mode
    )

    error_message = "billing_mode must be PAY_PER_REQUEST or PROVISIONED."
  }
}

variable "read_capacity" {
  description = "Read capacity units when using PROVISIONED billing."
  type        = number
  default     = 5
}

variable "write_capacity" {
  description = "Write capacity units when using PROVISIONED billing."
  type        = number
  default     = 5
}

variable "point_in_time_recovery_enabled" {
  description = "Enable point-in-time recovery."
  type        = bool
  default     = true
}

variable "deletion_protection_enabled" {
  description = "Prevent table deletion through AWS."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Additional tags for the orders table."
  type        = map(string)
  default     = {}
}