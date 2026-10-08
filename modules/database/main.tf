resource "aws_dynamodb_table" "orders" {
  name         = var.table_name
  billing_mode = var.billing_mode

  hash_key = "order_id"

  # Capacity settings apply only to provisioned billing.
  read_capacity = (
    var.billing_mode == "PROVISIONED"
    ? var.read_capacity
    : null
  )

  write_capacity = (
    var.billing_mode == "PROVISIONED"
    ? var.write_capacity
    : null
  )

  attribute {
    name = "order_id"
    type = "S"
  }

  point_in_time_recovery {
    enabled = var.point_in_time_recovery_enabled
  }

  server_side_encryption {
    enabled = true
  }

  deletion_protection_enabled = var.deletion_protection_enabled

  tags = merge(var.tags, {
    Name      = var.table_name
    Component = "OrdersDatabase"
  })
}