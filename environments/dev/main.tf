module "database" {
  source                         = "../../modules/database"
  table_name                     = "${var.project}-${var.environment}-orders"
  billing_mode                   = "PAY_PER_REQUEST"
  point_in_time_recovery_enabled = true
  deletion_protection_enabled    = false
  tags = {
    Environment = var.environment
    Project     = var.project
  }
}

//lambda module

module "order_lambda" {
  source                 = "../../modules/lambda"
  function_name          = "${var.project}-${var.environment}-order-api"
  orders_table_name      = module.database.table_name
  orders_table_arn       = module.database.table_arn
  idempotency_table_name = module.database.idempotency_table_name
  idempotency_table_arn  = module.database.idempotency_table_arn
  outbox_table_name      = module.database.outbox_table_name
  outbox_table_arn       = module.database.outbox_table_arn
  handler_file           = "${path.module}/../../services/order_api/src/handler.py"
  log_retention_days     = 14
  tags = {
    Component = "OrderAPI"
  }
}

//api module

module "api" {
  cognito_user_pool_arn = module.auth.user_pool_arn
  source                = "../../modules/api"

  api_name   = "${var.project}-${var.environment}-orders"
  stage_name = var.environment

  lambda_function_name = module.order_lambda.function_name
  lambda_invoke_arn    = module.order_lambda.invoke_arn

  api_access_log_group_arn          = module.observability.api_access_log_group_arn
  manage_apigateway_logging_account = var.manage_apigateway_logging_account



  tags = {
    Component = "OrderAPI"
  }
}

//auth module

module "auth" {
  source = "../../modules/auth"

  name          = "${var.project}-${var.environment}-users"
  domain_prefix = var.cognito_domain_prefix
  callback_urls = var.oauth_callback_urls

  tags = {
    Component = "Authentication"
  }
}

module "waf" {
  source = "../../modules/waf"

  name          = "${var.project}-${var.environment}-waf"
  api_stage_arn = module.api.stage_arn
  rate_limit    = 2000

  tags = {
    Component = "Security"
  }
}

module "event_bus" {
  source = "../../modules/event_bus"
  name   = "${var.project}-${var.environment}-events"
  tags = {
    Component = "OrderEvents"
  }
}
module "outbox_publisher" {
  source            = "../../modules/outbox_publisher"
  function_name     = "${var.project}-${var.environment}-outbox-publisher"
  outbox_stream_arn = module.database.outbox_stream_arn
  event_bus_arn     = module.event_bus.bus_arn
  handler_file      = "${path.module}/../../services/outbox_publisher/src/handler.py"
  tags = {
    Component = "OutboxPublisher"
  }
  # Install the verification target before beginning stream publication.
  depends_on = [module.event_bus]
}

module "order_consumer" {
  source = "../../modules/order_consumer"

  name              = "${var.project}-${var.environment}-order-processor"
  event_bus_name    = module.event_bus.bus_name
  orders_table_name = module.database.table_name
  orders_table_arn  = module.database.table_arn
  handler_file      = "${path.module}/../../services/order_processor/src/handler.py"

  maximum_concurrency = 2
  max_receive_count   = 5
  log_retention_days  = 14

  # Optional: supply existing SNS topic ARNs for alarm notifications.
  alarm_actions = [module.alerting.topic_arn]

  tags = {
    Component = "OrderProcessor"
  }
}


module "notification_consumer" {
  source = "../../modules/event_consumer"

  name           = "${var.project}-${var.environment}-notifications"
  consumer_kind  = "notifications"
  event_bus_name = module.event_bus.bus_name
  handler_file   = "${path.module}/../../services/event_consumer/src/handler.py"

  maximum_concurrency = 2
  max_receive_count   = 5
  alarm_actions       = [module.alerting.topic_arn]
  tags = {
    Component = "Notifications"
  }
}

module "analytics_consumer" {
  source = "../../modules/event_consumer"

  name           = "${var.project}-${var.environment}-analytics"
  consumer_kind  = "analytics"
  event_bus_name = module.event_bus.bus_name
  handler_file   = "${path.module}/../../services/event_consumer/src/handler.py"

  maximum_concurrency = 2
  max_receive_count   = 5
  alarm_actions       = [module.alerting.topic_arn]
  tags = {
    Component = "Analytics"
  }
}

# Optional email worker. Nothing is sent until explicitly enabled in tfvars.
module "email_sender" {
  count  = var.enable_email_delivery ? 1 : 0
  source = "../../modules/email_sender"

  name                     = "${var.project}-${var.environment}-email-sender"
  notifications_table_name = module.notification_consumer.records_table_name
  notifications_table_arn  = module.notification_consumer.records_table_arn
  cognito_user_pool_id     = module.auth.user_pool_id
  cognito_user_pool_arn    = module.auth.user_pool_arn
  ses_sender_email         = var.ses_sender_email
  ses_identity_arn         = var.ses_identity_arn
  handler_file             = "${path.module}/../../services/email_sender/src/handler.py"
  batch_limit              = 1
  alarm_actions            = [module.alerting.topic_arn]
  tags = {
    Component = "EmailDelivery"
  }
}
module "alerting" {
  source                     = "../../modules/alerting"
  name                       = "${var.project}-${var.environment}-alerts"
  alert_emails               = var.alert_emails
  failed_batches_bucket_name = module.outbox_publisher.failed_batches_bucket
  tags                       = { Component = "Alerting" }
}

module "observability" {
  source          = "../../modules/observability"
  name            = "${var.project}-${var.environment}"
  api_name        = "${var.project}-${var.environment}-orders"
  stage_name      = var.environment
  alarm_topic_arn = module.alerting.topic_arn

  functions = merge({
    order_api = {
      name    = module.order_lambda.function_name, log_group = module.order_lambda.log_group_name
      timeout = 15, failure_phrase = "Order API failed"
    }
    publisher = {
      name    = module.outbox_publisher.function_name, log_group = module.outbox_publisher.log_group_name
      timeout = 60, failure_phrase = "Outbox publication failed"
    }
    processor = {
      name    = module.order_consumer.function_name, log_group = module.order_consumer.log_group_name
      timeout = 30, failure_phrase = "Order processing failed"
    }
    notifications = {
      name    = module.notification_consumer.function_name, log_group = module.notification_consumer.log_group_name
      timeout = 30, failure_phrase = "Consumer failed"
    }
    analytics = {
      name    = module.analytics_consumer.function_name, log_group = module.analytics_consumer.log_group_name
      timeout = 30, failure_phrase = "Consumer failed"
    }
    }, var.enable_email_delivery ? {
    email = {
      name    = module.email_sender[0].function_name, log_group = module.email_sender[0].log_group_name
      timeout = 60, failure_phrase = ""
    }
  } : {})

  publisher_function_name = module.outbox_publisher.function_name

  queues = {
    order                  = basename(module.order_consumer.queue_url)
    order_processing_dlq   = basename(module.order_consumer.processing_dlq_url)
    order_delivery_dlq     = basename(module.order_consumer.delivery_dlq_url)
    notifications          = basename(module.notification_consumer.queue_url)
    notifications_dlq      = basename(module.notification_consumer.processing_dlq_url)
    notifications_delivery = basename(module.notification_consumer.delivery_dlq_url)
    analytics              = basename(module.analytics_consumer.queue_url)
    analytics_dlq          = basename(module.analytics_consumer.processing_dlq_url)
    analytics_delivery     = basename(module.analytics_consumer.delivery_dlq_url)
  }
  tables = {
    orders        = module.database.table_name
    idempotency   = module.database.idempotency_table_name
    outbox        = module.database.outbox_table_name
    processed     = module.order_consumer.processed_events_table_name
    notifications = module.notification_consumer.records_table_name
    analytics     = module.analytics_consumer.records_table_name
  }
  tags = { Component = "Observability" }
}


