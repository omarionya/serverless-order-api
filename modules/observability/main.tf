resource "aws_cloudwatch_log_group" "api_access" {
  name              = "/aws/apigateway/${var.name}-access"
  retention_in_days = 14
  tags              = var.tags
}

resource "aws_cloudwatch_log_metric_filter" "handled_failure" {
  for_each = {
    for key, function in var.functions : key => function
    if function.failure_phrase != ""
  }
  name           = "${var.name}-${each.key}-handled-failures"
  log_group_name = each.value.log_group
  pattern        = "\"${each.value.failure_phrase}\""
  metric_transformation {
    name          = "${each.key}HandledFailures"
    namespace     = "OrderAPI/${var.name}"
    value         = "1"
    default_value = 0
  }
}

resource "aws_cloudwatch_metric_alarm" "handled_failure" {
  for_each            = aws_cloudwatch_log_metric_filter.handled_failure
  alarm_name          = "${var.name}-${each.key}-handled-failures"
  alarm_description   = "Application reported failure; inspect this function's logs and relevant DLQ."
  namespace           = "OrderAPI/${var.name}"
  metric_name         = "${each.key}HandledFailures"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alarm_topic_arn]
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  # Optional email worker already has a native Errors alarm in chunk 6.
  for_each            = { for key, function in var.functions : key => function if key != "email" }
  alarm_name          = "${var.name}-${each.key}-runtime-errors"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = each.value.name }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alarm_topic_arn]
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "lambda_throttles" {
  for_each            = var.functions
  alarm_name          = "${var.name}-${each.key}-throttles"
  namespace           = "AWS/Lambda"
  metric_name         = "Throttles"
  dimensions          = { FunctionName = each.value.name }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alarm_topic_arn]
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "lambda_duration" {
  for_each                              = var.functions
  alarm_name                            = "${var.name}-${each.key}-duration"
  namespace                             = "AWS/Lambda"
  metric_name                           = "Duration"
  dimensions                            = { FunctionName = each.value.name }
  extended_statistic                    = "p95"
  period                                = 300
  evaluation_periods                    = 2
  evaluate_low_sample_count_percentiles = "ignore"
  comparison_operator                   = "GreaterThanThreshold"
  threshold                             = each.value.timeout * 1000 * 0.8
  treat_missing_data                    = "notBreaching"
  alarm_actions                         = [var.alarm_topic_arn]
  tags                                  = var.tags
}

resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  alarm_name          = "${var.name}-api-5xx-rate"
  alarm_description   = "5xx rate exceeds 5% with at least five requests in a five-minute window."
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 5
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alarm_topic_arn]
  metric_query {
    id          = "rate"
    expression  = "IF(requests >= 5, 100 * FILL(errors, 0) / requests, 0)"
    label       = "API 5xx percentage"
    return_data = true
  }
  metric_query {
    id          = "requests"
    return_data = false
    metric {
      namespace   = "AWS/ApiGateway"
      metric_name = "Count"
      dimensions  = { ApiName = var.api_name, Stage = var.stage_name }
      period      = 300
      stat        = "Sum"
    }
  }
  metric_query {
    id          = "errors"
    return_data = false
    metric {
      namespace   = "AWS/ApiGateway"
      metric_name = "5XXError"
      dimensions  = { ApiName = var.api_name, Stage = var.stage_name }
      period      = 300
      stat        = "Sum"
    }
  }
  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "api_latency" {
  alarm_name                            = "${var.name}-api-latency"
  namespace                             = "AWS/ApiGateway"
  metric_name                           = "Latency"
  dimensions                            = { ApiName = var.api_name, Stage = var.stage_name }
  extended_statistic                    = "p95"
  period                                = 300
  evaluation_periods                    = 2
  evaluate_low_sample_count_percentiles = "ignore"
  comparison_operator                   = "GreaterThanThreshold"
  threshold                             = var.api_latency_threshold_ms
  treat_missing_data                    = "notBreaching"
  alarm_actions                         = [var.alarm_topic_arn]
  tags                                  = var.tags
}

resource "aws_cloudwatch_metric_alarm" "stream_age" {
  alarm_name          = "${var.name}-outbox-stream-age"
  namespace           = "AWS/Lambda"
  metric_name         = "IteratorAge"
  dimensions          = { FunctionName = var.publisher_function_name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.stream_age_threshold_ms
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alarm_topic_arn]
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "destination_failure" {
  alarm_name          = "${var.name}-publisher-failure-destination"
  namespace           = "AWS/Lambda"
  metric_name         = "DestinationDeliveryFailures"
  dimensions          = { FunctionName = var.publisher_function_name }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alarm_topic_arn]
  tags                = var.tags
}
