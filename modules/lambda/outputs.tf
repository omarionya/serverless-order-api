output "function_name" {
  value = aws_lambda_function.order_api.function_name
}
output "function_arn" {
  value = aws_lambda_function.order_api.arn
}
output "invoke_arn" {
  value = aws_lambda_function.order_api.invoke_arn
}
output "log_group_name" {
  value = aws_cloudwatch_log_group.order_api.name
}
