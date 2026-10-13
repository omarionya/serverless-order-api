aws_region  = "us-east-1"
project     = "order-api"
environment = "dev"
# Replace with a unique, lowercase prefix.
cognito_domain_prefix = "order-api-dev"

oauth_callback_urls               = ["https://oauth.pstmn.io/v1/callback"]
alert_emails                      = ["ciciliapatrick08@gmail.com"]
manage_apigateway_logging_account = true