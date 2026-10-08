terraform {
  backend "s3" {
    bucket       = "patonya-order-api-tfstate-102026"
    key          = "order-api/dev/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}