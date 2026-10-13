resource "aws_dynamodb_table" "orders" {
  name         = var.table_name
  billing_mode = var.billing_mode
  hash_key     = "order_id"

  read_capacity  = var.billing_mode == "PROVISIONED" ? var.read_capacity : null
  write_capacity = var.billing_mode == "PROVISIONED" ? var.write_capacity : null

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

resource "aws_dynamodb_table" "idempotency" {
  name         = "${var.table_name}-idempotency"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "request_key"

  attribute {
    name = "request_key"
    type = "S"
  }
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }
  point_in_time_recovery {
    enabled = var.point_in_time_recovery_enabled
  }
  server_side_encryption {
    enabled = true
  }
  deletion_protection_enabled = var.deletion_protection_enabled
  tags = merge(var.tags, {
    Name      = "${var.table_name}-idempotency"
    Component = "Idempotency"
  })
}

resource "aws_dynamodb_table" "outbox" {
  name         = "${var.table_name}-outbox"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "event_id"

  attribute {
    name = "event_id"
    type = "S"
  }
  stream_enabled   = true
  stream_view_type = "NEW_IMAGE"

  point_in_time_recovery {
    enabled = var.point_in_time_recovery_enabled
  }
  server_side_encryption {
    enabled = true
  }
  deletion_protection_enabled = var.deletion_protection_enabled
  tags = merge(var.tags, {
    Name      = "${var.table_name}-outbox"
    Component = "Outbox"
  })
}
