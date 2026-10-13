output "function_name" {
  value = aws_lambda_function.publisher.function_name
}
output "log_group_name" {
  value = aws_cloudwatch_log_group.publisher.name
}
output "failed_batches_bucket" {
  value = aws_s3_bucket.failed_batches.id
}
