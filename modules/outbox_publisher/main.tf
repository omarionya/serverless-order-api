data "aws_caller_identity" "current" {}

data "archive_file" "publisher" {
  type = "zip"
  source {
    content  = file(var.handler_file)
    filename = "handler.py"
  }
  output_path = "${path.root}/${var.function_name}.zip"
}

resource "aws_s3_bucket" "failed_batches" {
  bucket_prefix = "order-outbox-failures-"
  force_destroy = false
  tags = merge(var.tags, {
    Name = "${var.function_name}-failed-batches"
  })
}

resource "aws_s3_bucket_public_access_block" "failed_batches" {
  bucket                  = aws_s3_bucket.failed_batches.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "failed_batches" {
  bucket = aws_s3_bucket.failed_batches.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_iam_role_policy" "xray" {
  name = "${var.function_name}-xray"
  role = aws_iam_role.publisher.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
      Resource = "*"
    }]
  })
}

resource "aws_s3_bucket_server_side_encryption_configuration" "failed_batches" {
  bucket = aws_s3_bucket.failed_batches.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_policy" "failed_batches" {
  bucket = aws_s3_bucket.failed_batches.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.failed_batches.arn,
        "${aws_s3_bucket.failed_batches.arn}/*"
      ]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

resource "aws_cloudwatch_log_group" "publisher" {
  name              = "/aws/lambda/${var.function_name}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_iam_role" "publisher" {
  name = "${var.function_name}-execution"
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

resource "aws_iam_role_policy" "publisher" {
  name = "${var.function_name}-permissions"
  role = aws_iam_role.publisher.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:DescribeStream",
          "dynamodb:GetRecords",
          "dynamodb:GetShardIterator"
        ]
        Resource = var.outbox_stream_arn
      },
      {
        Effect   = "Allow"
        Action   = "dynamodb:ListStreams"
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "events:PutEvents"
        Resource = var.event_bus_arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.publisher.arn}:*"
      },
      {
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.failed_batches.arn,
          "${aws_s3_bucket.failed_batches.arn}/*"
        ]
        Condition = {
          StringEquals = { "s3:ResourceAccount" = data.aws_caller_identity.current.account_id }
        }
      }
    ]
  })
}

resource "aws_lambda_function" "publisher" {

  tracing_config {
    mode = "Active"
  }
  function_name    = var.function_name
  role             = aws_iam_role.publisher.arn
  filename         = data.archive_file.publisher.output_path
  source_code_hash = data.archive_file.publisher.output_base64sha256
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 60
  memory_size      = 256
  environment {
    variables = {
      EVENT_BUS_ARN = var.event_bus_arn
    }
  }
  tags       = var.tags
  depends_on = [aws_iam_role_policy.publisher, aws_iam_role_policy.xray]
}

resource "aws_lambda_event_source_mapping" "outbox" {
  event_source_arn  = var.outbox_stream_arn
  function_name     = aws_lambda_function.publisher.arn
  starting_position = "TRIM_HORIZON"

  batch_size                         = 10
  maximum_batching_window_in_seconds = 1
  maximum_retry_attempts             = 20
  maximum_record_age_in_seconds      = 3600
  bisect_batch_on_function_error     = true
  function_response_types            = ["ReportBatchItemFailures"]

  filter_criteria {
    filter {
      pattern = jsonencode({ eventName = ["INSERT"] })
    }
  }

  destination_config {
    on_failure {
      destination_arn = aws_s3_bucket.failed_batches.arn
    }
  }
  depends_on = [
    aws_iam_role_policy.publisher,
    aws_s3_bucket_public_access_block.failed_batches,
    aws_s3_bucket_versioning.failed_batches,
    aws_s3_bucket_server_side_encryption_configuration.failed_batches,
    aws_s3_bucket_policy.failed_batches
  ]
}
