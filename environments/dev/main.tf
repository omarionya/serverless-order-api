module "database" {
  source = "../../modules/database"

  table_name   = "${var.project}-${var.environment}-orders"
  billing_mode = "PAY_PER_REQUEST"

  point_in_time_recovery_enabled = true
  deletion_protection_enabled    = false

  tags = {
    Environment = var.environment
    Project     = var.project
  }
}

//lambda module

module "order_lambda" {
  source = "../../modules/lambda"

  function_name = "${var.project}-${var.environment}-order-api"

  orders_table_name = module.database.table_name
  orders_table_arn  = module.database.table_arn

  handler_file = "${path.module}/../../services/order_api/src/handler.py"

  log_retention_days = 14

  tags = {
    Component = "OrderAPI"
  }
}