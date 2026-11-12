terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }

  # Remote state: S3 + DynamoDB locking. Supplied per environment with
  #   terraform init -backend-config=envs/<env>.backend.hcl
  backend "s3" {}
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.common_tags
  }
}
