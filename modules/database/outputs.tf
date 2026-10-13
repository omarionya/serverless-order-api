output "table_name" {
  value = aws_dynamodb_table.orders.name
}
output "table_arn" {
  value = aws_dynamodb_table.orders.arn
}
output "hash_key" {
  value = aws_dynamodb_table.orders.hash_key
}
output "idempotency_table_name" {
  value = aws_dynamodb_table.idempotency.name
}
output "idempotency_table_arn" {
  value = aws_dynamodb_table.idempotency.arn
}
output "outbox_table_name" {
  value = aws_dynamodb_table.outbox.name
}
output "outbox_table_arn" {
  value = aws_dynamodb_table.outbox.arn
}
output "outbox_stream_arn" {
  value = aws_dynamodb_table.outbox.stream_arn
}
