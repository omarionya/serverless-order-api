output "table_name" {
  description = "Orders table name."
  value       = aws_dynamodb_table.orders.name
}

output "table_arn" {
  description = "Orders table ARN."
  value       = aws_dynamodb_table.orders.arn
}

output "hash_key" {
  description = "Orders table partition key."
  value       = aws_dynamodb_table.orders.hash_key
}