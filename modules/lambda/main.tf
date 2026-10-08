# Package handler.py at the root of the ZIP.
data "archive_file" "order_api" {
  type = "zip"

  source {
    content  = file(var.handler_file)
    filename = "handler.py"
  }

  output_path = "${path.root}/${var.function_name}.zip"
}

# Allow the Lambda service to assume this execution role.
data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_execution" {
  name               = "${var.function_name}-execution"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json

  tags = var.tags
}

# Terraform creates the log group before the function.
resource "aws_cloudwatch_log_group" "order_api" {
  name              = "/aws/lambda/${var.function_name}"
  retention_in_days = var.log_retention_days

  tags = var.tags
}

# Allow reads/writes on this table and logging to this log group.
data "aws_iam_policy_document" "lambda_permissions" {
  statement {
    sid    = "OrdersTableAccess"
    effect = "Allow"

    actions = [
      "dynamodb:PutItem",
      "dynamodb:GetItem"
    ]

    resources = [var.orders_table_arn]
  }

  statement {
    sid    = "WriteFunctionLogs"
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]

    resources = [
      "${aws_cloudwatch_log_group.order_api.arn}:*"
    ]
  }
}

resource "aws_iam_role_policy" "lambda_permissions" {
  name   = "${var.function_name}-permissions"
  role   = aws_iam_role.lambda_execution.id
  policy = data.aws_iam_policy_document.lambda_permissions.json
}

resource "aws_lambda_function" "order_api" {
  function_name = var.function_name
  description   = "Creates and retrieves customer orders."
  role          = aws_iam_role.lambda_execution.arn

  filename         = data.archive_file.order_api.output_path
  source_code_hash = data.archive_file.order_api.output_base64sha256

  handler       = "handler.lambda_handler"
  runtime       = "python3.12"
  architectures = ["x86_64"]

  timeout     = 10
  memory_size = 256

  environment {
    variables = {
      ORDERS_TABLE = var.orders_table_name
    }
  }

  tags = var.tags

  depends_on = [
    aws_iam_role_policy.lambda_permissions,
    aws_cloudwatch_log_group.order_api
  ]
}