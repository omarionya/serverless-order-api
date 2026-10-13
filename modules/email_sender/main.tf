data "aws_caller_identity" "current" {}

data "archive_file" "sender" {
  type = "zip"
  source {
    content  = file(var.handler_file)
    filename = "handler.py"
  }
  output_path = "${path.root}/${var.name}.zip"
}

resource "aws_cloudwatch_log_group" "sender" {
  name              = "/aws/lambda/${var.name}"
  retention_in_days = 14
  tags              = var.tags
}

resource "aws_iam_role" "sender" {
  name = "${var.name}-execution"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy" "sender" {
  name = "${var.name}-permissions"
  role = aws_iam_role.sender.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "dynamodb:Query"
        Resource = "${var.notifications_table_arn}/index/delivery-status-index"
      },
      {
        Effect   = "Allow"
        Action   = "dynamodb:UpdateItem"
        Resource = var.notifications_table_arn
      },
      {
        Effect   = "Allow"
        Action   = "cognito-idp:ListUsers"
        Resource = var.cognito_user_pool_arn
      },
      {
        Effect   = "Allow"
        Action   = "ses:SendEmail"
        Resource = var.ses_identity_arn
        Condition = {
          StringEquals = { "ses:FromAddress" = var.ses_sender_email }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.sender.arn}:*"
      }
    ]
  })
}

resource "aws_lambda_function" "sender" {
  function_name    = var.name
  role             = aws_iam_role.sender.arn
  filename         = data.archive_file.sender.output_path
  source_code_hash = data.archive_file.sender.output_base64sha256
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 60
  memory_size      = 256
  environment {
    variables = {
      NOTIFICATIONS_TABLE = var.notifications_table_name
      COGNITO_POOL_ID     = var.cognito_user_pool_id
      SES_SENDER_EMAIL    = var.ses_sender_email
      BATCH_LIMIT         = tostring(var.batch_limit)
    }
  }
  lifecycle {
    precondition {
      condition     = var.ses_sender_email != "" && var.ses_identity_arn != ""
      error_message = "Enabling email requires an existing verified SES sender and its identity ARN."
    }
  }
  tags       = var.tags
  depends_on = [aws_iam_role_policy.sender]
}

resource "aws_scheduler_schedule_group" "email" {
  name = var.name
  tags = var.tags
}

resource "aws_iam_role" "scheduler" {
  name = "${var.name}-scheduler"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "scheduler.amazonaws.com" }
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        ArnEquals    = { "aws:SourceArn" = aws_scheduler_schedule_group.email.arn }
      }
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy" "scheduler" {
  name = "invoke-email-worker"
  role = aws_iam_role.scheduler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.sender.arn
    }]
  })
}

resource "aws_scheduler_schedule" "email" {
  name                = "pending-emails"
  group_name          = aws_scheduler_schedule_group.email.name
  schedule_expression = "rate(1 minute)"
  flexible_time_window {
    mode = "OFF"
  }
  target {
    arn      = aws_lambda_function.sender.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ source = "notification-scheduler" })
    retry_policy {
      maximum_event_age_in_seconds = 60
      maximum_retry_attempts       = 0
    }
  }
  depends_on = [aws_iam_role_policy.scheduler]
}
