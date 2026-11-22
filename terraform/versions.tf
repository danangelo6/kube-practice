terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.95"
    }
  }

  # Bucket/key/region are passed at init time: see README step 3.
  # use_lockfile = S3-native state locking (no DynamoDB table needed).
  backend "s3" {
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}
