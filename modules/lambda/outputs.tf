output "function_name" {
  description = "Lambda function name."
  value       = aws_lambda_function.order_api.function_name
}

output "function_arn" {
  description = "Lambda function ARN."
  value       = aws_lambda_function.order_api.arn
}

output "invoke_arn" {
  description = "Invocation ARN for API Gateway integration."
  value       = aws_lambda_function.order_api.invoke_arn
}

output "log_group_name" {
  description = "CloudWatch log group name."
  value       = aws_cloudwatch_log_group.order_api.name
}