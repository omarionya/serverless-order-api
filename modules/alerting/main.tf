data "aws_partition" "current" {}
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

resource "aws_sns_topic" "alerts" {
  name = var.name
  tags = var.tags
}

resource "aws_sns_topic_policy" "alerts" {
  arn = aws_sns_topic.alerts.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "OwnerAccess"
        Effect    = "Allow"
        Principal = { AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action = [
          "sns:AddPermission",
          "sns:DeleteTopic",
          "sns:GetTopicAttributes",
          "sns:ListSubscriptionsByTopic",
          "sns:Publish",
          "sns:RemovePermission",
          "sns:SetTopicAttributes",
          "sns:Subscribe"
        ]
        Resource = aws_sns_topic.alerts.arn
      },
      {
        Sid       = "CloudWatchAlarmNotifications"
        Effect    = "Allow"
        Principal = { Service = "cloudwatch.amazonaws.com" }
        Action    = "SNS:Publish"
        Resource  = aws_sns_topic.alerts.arn
        Condition = {
          StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
          ArnLike      = { "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:cloudwatch:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:alarm:*" }
        }
      },
      {
        Sid       = "PublisherFailedBatchNotifications"
        Effect    = "Allow"
        Principal = { Service = "s3.amazonaws.com" }
        Action    = "SNS:Publish"
        Resource  = aws_sns_topic.alerts.arn
        Condition = {
          StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
          ArnEquals    = { "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:s3:::${var.failed_batches_bucket_name}" }
        }
      }
    ]
  })
}

resource "aws_sns_topic_subscription" "email" {
  for_each  = var.alert_emails
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

# S3 bucket notification configuration is a singleton per bucket. Merge this
# topic into an existing configuration if you have already added one.
resource "aws_s3_bucket_notification" "publisher_failures" {
  bucket = var.failed_batches_bucket_name
  topic {
    topic_arn = aws_sns_topic.alerts.arn
    events    = ["s3:ObjectCreated:*"]
  }
  depends_on = [aws_sns_topic_policy.alerts]
}
