locals {
  function_timeout = 30
  batch_window     = 1
}

# Failures after a message has reached the consumer queue.
resource "aws_sqs_queue" "processing_dlq" {
  name                      = "${var.name}-processing-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
  tags                      = var.tags
}

# Failures delivering from EventBridge to the consumer queue.
resource "aws_sqs_queue" "delivery_dlq" {
  name                      = "${var.name}-delivery-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
  tags                      = var.tags
}

resource "aws_sqs_queue" "orders" {
  name                       = "${var.name}-queue"
  message_retention_seconds  = 345600
  receive_wait_time_seconds  = 20
  visibility_timeout_seconds = local.function_timeout * 6 + local.batch_window
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.processing_dlq.arn
    maxReceiveCount     = var.max_receive_count
  })
  tags = var.tags
}

resource "aws_sqs_queue_redrive_allow_policy" "processing_dlq" {
  queue_url = aws_sqs_queue.processing_dlq.url
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.orders.arn]
  })
}

# Durable deduplication for this consumer. No TTL: old event replays must not
# repeat the state transition. Other consumers need their own namespace/table.
resource "aws_dynamodb_table" "processed_events" {
  name         = "${var.name}-processed-events"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "event_id"
  attribute {
    name = "event_id"
    type = "S"
  }
  point_in_time_recovery {
    enabled = true
  }
  server_side_encryption {
    enabled = true
  }
  tags = var.tags
}

data "archive_file" "processor" {
  type = "zip"
  source {
    content  = file(var.handler_file)
    filename = "handler.py"
  }
  output_path = "${path.root}/${var.name}.zip"
}

resource "aws_cloudwatch_log_group" "processor" {
  name              = "/aws/lambda/${var.name}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_iam_role" "processor" {
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

resource "aws_iam_role_policy" "processor" {
  name = "${var.name}-permissions"
  role = aws_iam_role.processor.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = aws_sqs_queue.orders.arn
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem"]
        Resource = aws_dynamodb_table.processed_events.arn
      },
      {
        Effect   = "Allow"
        Action   = "dynamodb:UpdateItem"
        Resource = var.orders_table_arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.processor.arn}:*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "xray" {
  name = "${var.name}-xray"
  role = aws_iam_role.processor.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
      Resource = "*"
    }]
  })
}


resource "aws_lambda_function" "processor" {

  tracing_config {
    mode = "Active"
  }
  function_name    = var.name
  description      = "Idempotent OrderCreated consumer: atomically begins order processing."
  role             = aws_iam_role.processor.arn
  filename         = data.archive_file.processor.output_path
  source_code_hash = data.archive_file.processor.output_base64sha256
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = local.function_timeout
  memory_size      = 256
  environment {
    variables = {
      ORDERS_TABLE           = var.orders_table_name
      PROCESSED_EVENTS_TABLE = aws_dynamodb_table.processed_events.name
    }
  }
  tags       = var.tags
  depends_on = [aws_iam_role_policy.processor, aws_iam_role_policy.xray]
}

resource "aws_lambda_event_source_mapping" "orders" {
  event_source_arn                   = aws_sqs_queue.orders.arn
  function_name                      = aws_lambda_function.processor.arn
  batch_size                         = 10
  maximum_batching_window_in_seconds = local.batch_window
  function_response_types            = ["ReportBatchItemFailures"]
  scaling_config {
    maximum_concurrency = var.maximum_concurrency
  }
  depends_on = [
    aws_iam_role_policy.processor,
    aws_sqs_queue_redrive_allow_policy.processing_dlq
  ]
}

resource "aws_cloudwatch_event_rule" "order_created" {
  name           = "${var.name}-created"
  event_bus_name = var.event_bus_name
  event_pattern = jsonencode({
    source        = ["com.example.orders"]
    "detail-type" = ["OrderCreated"]
  })
  tags = var.tags
}

data "aws_iam_policy_document" "eventbridge_delivery" {
  for_each = {
    orders       = aws_sqs_queue.orders.arn
    delivery_dlq = aws_sqs_queue.delivery_dlq.arn
  }
  statement {
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [each.value]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.order_created.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "eventbridge_delivery" {
  for_each = {
    orders       = aws_sqs_queue.orders.url
    delivery_dlq = aws_sqs_queue.delivery_dlq.url
  }
  queue_url = each.value
  policy    = data.aws_iam_policy_document.eventbridge_delivery[each.key].json
}

resource "aws_cloudwatch_event_target" "orders" {
  event_bus_name = var.event_bus_name
  rule           = aws_cloudwatch_event_rule.order_created.name
  target_id      = "order-processor-queue"
  arn            = aws_sqs_queue.orders.arn
  retry_policy {
    maximum_event_age_in_seconds = 86400
    maximum_retry_attempts       = 185
  }
  dead_letter_config {
    arn = aws_sqs_queue.delivery_dlq.arn
  }
  depends_on = [aws_sqs_queue_policy.eventbridge_delivery]
}
