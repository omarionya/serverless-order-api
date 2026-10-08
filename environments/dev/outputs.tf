output "orders_table_name" {
  value = module.database.table_name
}

output "orders_table_arn" {
  value = module.database.table_arn
}

output "order_lambda_name" {
  value = module.order_lambda.function_name
}

output "order_lambda_arn" {
  value = module.order_lambda.function_arn
}

output "order_lambda_log_group" {
  value = module.order_lambda.log_group_name
}