resource "aws_dynamodb_table_item" "sample_order" {
  table_name = module.database.table_name
  hash_key   = module.database.hash_key

  item = file("${path.module}/seed/order.json")
}