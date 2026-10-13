resource "aws_iam_role_policy" "xray" {
  name = "${var.function_name}-xray"
  role = aws_iam_role.lambda_execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
      Resource = "*"
    }]
  })
}

data "archive_file" "order_api" {
  type = "zip"
  source {
    content  = file(var.handler_file)
    filename = "handler.py"
  }
  output_path = "${path.root}/${var.function_name}.zip"
}

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
  tags               = var.tags
}

resource "aws_cloudwatch_log_group" "order_api" {
  name              = "/aws/lambda/${var.function_name}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

data "aws_iam_policy_document" "lambda_permissions" {
  # Transactional Put operations are authorized using PutItem permissions.
  statement {
    sid     = "TransactionWrites"
    effect  = "Allow"
    actions = ["dynamodb:PutItem"]
    resources = [
      var.orders_table_arn,
      var.idempotency_table_arn,
      var.outbox_table_arn
    ]
  }
  statement {
    sid       = "ReadOrdersAndIdempotency"
    effect    = "Allow"
    actions   = ["dynamodb:GetItem"]
    resources = [var.orders_table_arn, var.idempotency_table_arn]
  }
  statement {
    sid       = "WriteFunctionLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.order_api.arn}:*"]
  }
}

resource "aws_iam_role_policy" "lambda_permissions" {
  name   = "${var.function_name}-permissions"
  role   = aws_iam_role.lambda_execution.id
  policy = data.aws_iam_policy_document.lambda_permissions.json
}

resource "aws_lambda_function" "order_api" {
  tracing_config {
    mode = "Active"
  }

  function_name    = var.function_name
  description      = "Creates orders atomically with idempotency and outbox events."
  role             = aws_iam_role.lambda_execution.arn
  filename         = data.archive_file.order_api.output_path
  source_code_hash = data.archive_file.order_api.output_base64sha256
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  architectures    = ["x86_64"]
  timeout          = 15
  memory_size      = 256
  environment {
    variables = {
      ORDERS_TABLE      = var.orders_table_name
      IDEMPOTENCY_TABLE = var.idempotency_table_name
      OUTBOX_TABLE      = var.outbox_table_name
    }
  }
  tags = var.tags
  depends_on = [
    aws_iam_role_policy.lambda_permissions,
    aws_iam_role_policy.xray,
    aws_cloudwatch_log_group.order_api
  ]
}
