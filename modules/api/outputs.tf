output "api_url" {
  description = "Base URL including the deployed stage."
  value       = aws_api_gateway_stage.dev.invoke_url
}

output "execution_arn" {
  description = "API execution ARN for caller IAM policies."
  value       = aws_api_gateway_rest_api.orders.execution_arn
}

output "stage_arn" {
  description = "Stage ARN for a future WAF association."
  value       = aws_api_gateway_stage.dev.arn
}

