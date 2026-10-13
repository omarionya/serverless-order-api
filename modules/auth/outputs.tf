data "aws_region" "current" {}

output "user_pool_id" {
  value = aws_cognito_user_pool.orders.id
}

output "user_pool_arn" {
  value = aws_cognito_user_pool.orders.arn
}

output "client_id" {
  value = aws_cognito_user_pool_client.orders.id
}

output "oauth_base_url" {
  value = "https://${aws_cognito_user_pool_domain.orders.domain}.auth.${data.aws_region.current.region}.amazoncognito.com"
}