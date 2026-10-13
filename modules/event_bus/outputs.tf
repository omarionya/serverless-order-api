output "bus_name" {
  value = aws_cloudwatch_event_bus.orders.name
}
output "bus_arn" {
  value = aws_cloudwatch_event_bus.orders.arn
}
output "verification_queue_url" {
  value = aws_sqs_queue.verification.url
}
output "delivery_dlq_url" {
  value = aws_sqs_queue.delivery_dlq.url
}
