resource "aws_cloudwatch_log_metric_filter" "review" {
  name           = "${var.name}-review"
  log_group_name = aws_cloudwatch_log_group.sender.name
  pattern        = "\"Email requires review\""
  metric_transformation {
    name      = "ReviewRequired"
    namespace = "OrderNotifications/${var.name}"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "review" {
  alarm_name          = "${var.name}-review-required"
  namespace           = "OrderNotifications/${var.name}"
  metric_name         = "ReviewRequired"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_actions
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "errors" {
  alarm_name          = "${var.name}-errors"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.sender.function_name }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_actions
  tags                = var.tags
}
