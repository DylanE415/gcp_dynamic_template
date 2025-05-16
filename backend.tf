terraform {
  backend "s3" {
    bucket = "cloudgo-state-storage"
    key    = "project1/terraform.tfstate"
    region = "us-east-2"
  }
}
