output "orders_table_name" {
  value = module.database.table_name
}

output "orders_table_arn" {
  value = module.database.table_arn
}

output "order_lambda_name" {
  value = module.order_lambda.function_name
}

output "order_lambda_arn" {
  value = module.order_lambda.function_arn
}

output "order_lambda_log_group" {
  value = module.order_lambda.log_group_name
}


output "api_url" {
  value = module.api.api_url
}

output "api_execution_arn" {
  value = module.api.execution_arn
}

output "cognito_user_pool_id" {
  value = module.auth.user_pool_id
}

output "cognito_client_id" {
  value = module.auth.client_id
}

output "cognito_oauth_base_url" {
  value = module.auth.oauth_base_url
}

output "waf_arn" {
  value = module.waf.web_acl_arn
}

output "idempotency_table_name" {
  value = module.database.idempotency_table_name
}
output "outbox_table_name" {
  value = module.database.outbox_table_name
}
output "event_bus_name" {
  value = module.event_bus.bus_name
}
output "verification_queue_url" {
  value = module.event_bus.verification_queue_url
}
output "event_delivery_dlq_url" {
  value = module.event_bus.delivery_dlq_url
}
output "publisher_function_name" {
  value = module.outbox_publisher.function_name
}
output "publisher_log_group" {
  value = module.outbox_publisher.log_group_name
}
output "publisher_failed_batches_bucket" {
  value = module.outbox_publisher.failed_batches_bucket
}

# ADD these outputs to environment/dev/outputs.tf.
output "order_processor_name" {
  value = module.order_consumer.function_name
}
output "order_processor_log_group" {
  value = module.order_consumer.log_group_name
}
output "order_processing_queue_url" {
  value = module.order_consumer.queue_url
}
output "order_processing_queue_arn" {
  value = module.order_consumer.queue_arn
}
output "order_processing_dlq_url" {
  value = module.order_consumer.processing_dlq_url
}
output "order_processing_dlq_arn" {
  value = module.order_consumer.processing_dlq_arn
}
output "order_delivery_dlq_url" {
  value = module.order_consumer.delivery_dlq_url
}
output "order_processed_events_table" {
  value = module.order_consumer.processed_events_table_name
}

//consumers

output "notification_function_name" {
  value = module.notification_consumer.function_name
}
output "notification_table_name" {
  value = module.notification_consumer.records_table_name
}
output "notification_queue_url" {
  value = module.notification_consumer.queue_url
}
output "notification_processing_dlq_url" {
  value = module.notification_consumer.processing_dlq_url
}
output "notification_delivery_dlq_url" {
  value = module.notification_consumer.delivery_dlq_url
}
output "analytics_function_name" {
  value = module.analytics_consumer.function_name
}
output "analytics_table_name" {
  value = module.analytics_consumer.records_table_name
}
output "analytics_queue_url" {
  value = module.analytics_consumer.queue_url
}
output "analytics_processing_dlq_url" {
  value = module.analytics_consumer.processing_dlq_url
}
output "analytics_delivery_dlq_url" {
  value = module.analytics_consumer.delivery_dlq_url
}
output "email_sender_function_name" {
  value = var.enable_email_delivery ? module.email_sender[0].function_name : null
}

output "alarm_topic_arn" {
  value = module.alerting.topic_arn
}
output "operations_dashboard_name" {
  value = module.observability.dashboard_name
}
output "api_access_log_group" {
  value = module.observability.api_access_log_group_name
}
output "reconciliation_tables" {
  description = "Read-only audit table configuration; contains names, not credentials."
  value = {
    outbox        = module.database.outbox_table_name
    orders        = module.database.table_name
    processed     = module.order_consumer.processed_events_table_name
    notifications = module.notification_consumer.records_table_name
    analytics     = module.analytics_consumer.records_table_name
  }
}