resource "aws_cognito_user_pool" "orders" {
  name = var.name

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length    = 12
    require_lowercase = true
    require_uppercase = true
    require_numbers   = true
    require_symbols   = true
  }

  # Create development users through the Cognito console.
  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  tags = var.tags
}

resource "aws_cognito_resource_server" "orders" {
  user_pool_id = aws_cognito_user_pool.orders.id

  identifier = "orders"
  name       = "Orders API"

  scope {
    scope_name        = "read"
    scope_description = "Read the authenticated customer's orders."
  }

  scope {
    scope_name        = "write"
    scope_description = "Create orders for the authenticated customer."
  }
}

resource "aws_cognito_user_pool_client" "orders" {
  name         = "${var.name}-client"
  user_pool_id = aws_cognito_user_pool.orders.id

  # Public client: use authorization code with PKCE.
  generate_secret = false

  supported_identity_providers = ["COGNITO"]

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]

  allowed_oauth_scopes = [
    "openid",
    "email",
    "orders/read",
    "orders/write"
  ]

  callback_urls = var.callback_urls

  access_token_validity  = 60
  id_token_validity      = 60
  refresh_token_validity = 7

  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }

  prevent_user_existence_errors = "ENABLED"

  depends_on = [
    aws_cognito_resource_server.orders
  ]
}

resource "aws_cognito_user_pool_domain" "orders" {
  domain       = var.domain_prefix
  user_pool_id = aws_cognito_user_pool.orders.id
}