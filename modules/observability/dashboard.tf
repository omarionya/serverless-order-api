data "aws_region" "current" {}

resource "aws_cloudwatch_dashboard" "orders" {
  dashboard_name = "${var.name}-operations"
  dashboard_body = jsonencode({
    widgets = [
      {
        type       = "text", x = 0, y = 0, width = 24, height = 3
        properties = { markdown = "# ${var.name} operations\nCorrelate order_id and stable detail.event_id across logs. Lambda Errors alone do not count handled HTTP/partial-batch failures. Missing metrics can mean no traffic or a disabled mapping; check the runbook." }
      },
      {
        type = "metric", x = 0, y = 3, width = 12, height = 6
        properties = {
          title = "API requests and errors", region = data.aws_region.current.region, period = 60, stat = "Sum"
          metrics = [
            ["AWS/ApiGateway", "Count", "ApiName", var.api_name, "Stage", var.stage_name],
            ["AWS/ApiGateway", "4XXError", "ApiName", var.api_name, "Stage", var.stage_name],
            ["AWS/ApiGateway", "5XXError", "ApiName", var.api_name, "Stage", var.stage_name]
          ]
        }
      },
      {
        type = "metric", x = 12, y = 3, width = 12, height = 6
        properties = {
          title   = "API latency p95 (ms)", region = data.aws_region.current.region, period = 300, stat = "p95"
          metrics = [["AWS/ApiGateway", "Latency", "ApiName", var.api_name, "Stage", var.stage_name]]
        }
      },
      {
        type = "metric", x = 0, y = 9, width = 12, height = 6
        properties = {
          title   = "Lambda runtime errors", region = data.aws_region.current.region, period = 60, stat = "Sum"
          metrics = [for key, function in var.functions : ["AWS/Lambda", "Errors", "FunctionName", function.name, { label = key }]]
        }
      },
      {
        type = "metric", x = 12, y = 9, width = 12, height = 6
        properties = {
          title   = "Handled application failures", region = data.aws_region.current.region, period = 60, stat = "Sum"
          metrics = [for key, function in var.functions : ["OrderAPI/${var.name}", "${key}HandledFailures", { label = key }] if function.failure_phrase != ""]
        }
      },
      {
        type = "metric", x = 0, y = 15, width = 12, height = 6
        properties = {
          title   = "Lambda duration p95 (ms)", region = data.aws_region.current.region, period = 300, stat = "p95"
          metrics = [for key, function in var.functions : ["AWS/Lambda", "Duration", "FunctionName", function.name, { label = key }]]
        }
      },
      {
        type = "metric", x = 12, y = 15, width = 12, height = 6
        properties = {
          title   = "Lambda throttles", region = data.aws_region.current.region, period = 60, stat = "Sum"
          metrics = [for key, function in var.functions : ["AWS/Lambda", "Throttles", "FunctionName", function.name, { label = key }]]
        }
      },
      {
        type = "metric", x = 0, y = 21, width = 12, height = 6
        properties = {
          title   = "Queue and DLQ visible messages", region = data.aws_region.current.region, period = 60, stat = "Maximum"
          metrics = [for key, name in var.queues : ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", name, { label = key }]]
        }
      },
      {
        type = "metric", x = 12, y = 21, width = 12, height = 6
        properties = {
          title   = "Queue oldest message age (seconds)", region = data.aws_region.current.region, period = 60, stat = "Maximum"
          metrics = [for key, name in var.queues : ["AWS/SQS", "ApproximateAgeOfOldestMessage", "QueueName", name, { label = key }]]
        }
      },
      {
        type = "metric", x = 0, y = 27, width = 12, height = 6
        properties = {
          title   = "Outbox stream age (ms)", region = data.aws_region.current.region, period = 60, stat = "Maximum"
          metrics = [["AWS/Lambda", "IteratorAge", "FunctionName", var.publisher_function_name]]
        }
      },
      {
        type = "metric", x = 12, y = 27, width = 12, height = 6
        properties = {
          title   = "Publisher failure-destination errors", region = data.aws_region.current.region, period = 60, stat = "Sum"
          metrics = [["AWS/Lambda", "DestinationDeliveryFailures", "FunctionName", var.publisher_function_name]]
        }
      },
      {
        type = "metric", x = 0, y = 33, width = 12, height = 6
        properties = {
          title   = "DynamoDB consumed write units", region = data.aws_region.current.region, period = 60, stat = "Sum"
          metrics = [for key, name in var.tables : ["AWS/DynamoDB", "ConsumedWriteCapacityUnits", "TableName", name, { label = key }]]
        }
      },
      {
        type = "metric", x = 12, y = 33, width = 12, height = 6
        properties = {
          title   = "DynamoDB table write throttles", region = data.aws_region.current.region, period = 60, stat = "Sum"
          metrics = [for key, name in var.tables : ["AWS/DynamoDB", "WriteThrottleEvents", "TableName", name, { label = key }]]
        }
      }
    ]
  })
}
