resource "aws_api_gateway_rest_api" "orders" {
  name        = var.api_name
  description = "Order creation and retrieval API."
  lifecycle {
    create_before_destroy = true
  }


  endpoint_configuration {
    types = ["REGIONAL"]
  }

  tags = var.tags
}

# /orders
resource "aws_api_gateway_resource" "orders" {
  rest_api_id = aws_api_gateway_rest_api.orders.id
  parent_id   = aws_api_gateway_rest_api.orders.root_resource_id
  path_part   = "orders"
}

# /orders/{id}
resource "aws_api_gateway_resource" "order" {
  rest_api_id = aws_api_gateway_rest_api.orders.id
  parent_id   = aws_api_gateway_resource.orders.id
  path_part   = "{id}"
}

locals {
  routes = {
    create_order = {
      resource_id = aws_api_gateway_resource.orders.id
      method      = "POST"
      path        = "orders"
    }

    get_order = {
      resource_id = aws_api_gateway_resource.order.id
      method      = "GET"
      path        = "orders/*"
    }
  }
}
resource "aws_api_gateway_method" "routes" {
  for_each = local.routes

  rest_api_id = aws_api_gateway_rest_api.orders.id
  resource_id = each.value.resource_id
  http_method = each.value.method

  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito.id

  authorization_scopes = [
    each.key == "create_order" ? "orders/write" : "orders/read"
  ]
}

resource "aws_api_gateway_integration" "routes" {
  for_each = local.routes

  rest_api_id = aws_api_gateway_rest_api.orders.id
  resource_id = each.value.resource_id
  http_method = aws_api_gateway_method.routes[each.key].http_method

  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = var.lambda_invoke_arn
}

# Allow this API's routes to invoke the Lambda.
resource "aws_lambda_permission" "api_gateway" {
  for_each = local.routes

  statement_id  = "AllowAPIGateway-${each.key}"
  action        = "lambda:InvokeFunction"
  function_name = var.lambda_function_name
  principal     = "apigateway.amazonaws.com"

  source_arn = "${aws_api_gateway_rest_api.orders.execution_arn}/*/${each.value.method}/${each.value.path}"
}

resource "aws_api_gateway_deployment" "orders" {
  rest_api_id = aws_api_gateway_rest_api.orders.id

  # Redeploy when route or integration configuration changes.
  triggers = {
    redeployment = sha1(jsonencode({
      resources = [
        aws_api_gateway_resource.orders.path,
        aws_api_gateway_resource.order.path
      ]

      methods = {
        for key, method in aws_api_gateway_method.routes :
        key => {
          http_method          = method.http_method
          authorization        = method.authorization
          authorizer_id        = method.authorizer_id
          authorization_scopes = method.authorization_scopes
          resource_id          = method.resource_id
        }
      }

      authorizer = {
        id            = aws_api_gateway_authorizer.cognito.id
        provider_arns = aws_api_gateway_authorizer.cognito.provider_arns
      }

      integrations = {
        for key, integration in aws_api_gateway_integration.routes :
        key => {
          type                    = integration.type
          uri                     = integration.uri
          integration_http_method = integration.integration_http_method
        }
      }
    }))

  }

  depends_on = [
    aws_api_gateway_integration.routes,
    aws_lambda_permission.api_gateway
  ]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "dev" {
  rest_api_id           = aws_api_gateway_rest_api.orders.id
  deployment_id         = aws_api_gateway_deployment.orders.id
  stage_name            = var.stage_name
  cache_cluster_enabled = true


  xray_tracing_enabled = true
  access_log_settings {
    destination_arn = var.api_access_log_group_arn
    format = jsonencode({
      request_id             = "$context.requestId"
      extended_request_id    = "$context.extendedRequestId"
      method                 = "$context.httpMethod"
      resource               = "$context.resourcePath"
      status                 = "$context.status"
      response_latency_ms    = "$context.responseLatency"
      integration_latency_ms = "$context.integrationLatency"
      integration_error      = "$context.integrationErrorMessage"
    })
  }
  depends_on = [aws_api_gateway_account.logging, aws_cloudwatch_log_group.execution]
  tags       = var.tags
}

resource "aws_api_gateway_method_settings" "throttling" {
  rest_api_id = aws_api_gateway_rest_api.orders.id
  stage_name  = aws_api_gateway_stage.dev.stage_name
  method_path = "*/*"

  settings {
    throttling_burst_limit = 20
    throttling_rate_limit  = 10
    logging_level          = "ERROR"
    data_trace_enabled     = false
    caching_enabled        = true
  }
}
resource "aws_api_gateway_authorizer" "cognito" {
  name        = "orders-cognito"
  rest_api_id = aws_api_gateway_rest_api.orders.id

  type            = "COGNITO_USER_POOLS"
  provider_arns   = [var.cognito_user_pool_arn]
  identity_source = "method.request.header.Authorization"
}

data "aws_partition" "logging" {}

resource "aws_iam_role" "api_logging" {
  count = var.manage_apigateway_logging_account ? 1 : 0
  name  = "${var.api_name}-logging"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "apigateway.amazonaws.com" }
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "api_logging" {
  count      = var.manage_apigateway_logging_account ? 1 : 0
  role       = aws_iam_role.api_logging[0].name
  policy_arn = "arn:${data.aws_partition.logging.partition}:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}

resource "aws_api_gateway_account" "logging" {
  count               = var.manage_apigateway_logging_account ? 1 : 0
  cloudwatch_role_arn = aws_iam_role.api_logging[0].arn
  depends_on          = [aws_iam_role_policy_attachment.api_logging]
}

resource "aws_cloudwatch_log_group" "execution" {
  name              = "API-Gateway-Execution-Logs_${aws_api_gateway_rest_api.orders.id}/${var.stage_name}"
  retention_in_days = 14
  tags              = var.tags
}
