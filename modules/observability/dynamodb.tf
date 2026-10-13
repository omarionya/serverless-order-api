resource "aws_cloudwatch_metric_alarm" "table_write_throttles" {
  for_each            = var.tables
  alarm_name          = "${var.name}-${each.key}-write-throttles"
  namespace           = "AWS/DynamoDB"
  metric_name         = "WriteThrottleEvents"
  dimensions          = { TableName = each.value }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alarm_topic_arn]
  tags                = var.tags
}
