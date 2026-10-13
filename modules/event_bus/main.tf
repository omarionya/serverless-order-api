resource "aws_cloudwatch_event_bus" "orders" {
  name = var.name
  tags = var.tags
}

# Development-only target to verify the complete publication path.
# Dedicated service queues will be added in chunk 5.
resource "aws_sqs_queue" "verification" {
  name                      = "${var.name}-verification"
  message_retention_seconds = 345600
  sqs_managed_sse_enabled   = true
  tags                      = var.tags
}

resource "aws_sqs_queue" "delivery_dlq" {
  name                      = "${var.name}-verification-delivery-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
  tags                      = var.tags
}

resource "aws_cloudwatch_event_rule" "order_created" {
  name           = "order-created-verification"
  event_bus_name = aws_cloudwatch_event_bus.orders.name
  event_pattern = jsonencode({
    source        = ["com.example.orders"]
    "detail-type" = ["OrderCreated"]
  })
  tags = var.tags
}

data "aws_iam_policy_document" "queue_delivery" {
  for_each = {
    verification = aws_sqs_queue.verification.arn
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

resource "aws_sqs_queue_policy" "queue_delivery" {
  for_each = {
    verification = aws_sqs_queue.verification.id
    delivery_dlq = aws_sqs_queue.delivery_dlq.id
  }
  queue_url = each.value
  policy    = data.aws_iam_policy_document.queue_delivery[each.key].json
}

resource "aws_cloudwatch_event_target" "verification" {
  rule           = aws_cloudwatch_event_rule.order_created.name
  event_bus_name = aws_cloudwatch_event_bus.orders.name
  target_id      = "verification-queue"
  arn            = aws_sqs_queue.verification.arn
  retry_policy {
    maximum_event_age_in_seconds = 86400
    maximum_retry_attempts       = 185
  }
  dead_letter_config {
    arn = aws_sqs_queue.delivery_dlq.arn
  }
  depends_on = [aws_sqs_queue_policy.queue_delivery]
}
