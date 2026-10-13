output "function_name" {
  value = aws_lambda_function.processor.function_name
}
output "log_group_name" {
  value = aws_cloudwatch_log_group.processor.name
}
output "queue_url" {
  value = aws_sqs_queue.orders.url
}
output "queue_arn" {
  value = aws_sqs_queue.orders.arn
}
output "processing_dlq_url" {
  value = aws_sqs_queue.processing_dlq.url
}
output "processing_dlq_arn" {
  value = aws_sqs_queue.processing_dlq.arn
}
output "delivery_dlq_url" {
  value = aws_sqs_queue.delivery_dlq.url
}
output "records_table_name" {
  value = aws_dynamodb_table.records.name
}

output "records_table_arn" {
  value = aws_dynamodb_table.records.arn
}
