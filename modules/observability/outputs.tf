output "api_access_log_group_arn" {
  value = aws_cloudwatch_log_group.api_access.arn
}
output "api_access_log_group_name" {
  value = aws_cloudwatch_log_group.api_access.name
}
output "dashboard_name" {
  value = aws_cloudwatch_dashboard.orders.dashboard_name
}
