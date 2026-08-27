terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.80.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.0"
    }
  }
}

provider "aws" {
  region                      = var.aws_region
  skip_credentials_validation = !var.enable_bedrock
  skip_requesting_account_id  = !var.enable_bedrock
  skip_metadata_api_check     = true
}

data "aws_caller_identity" "current" {
  count = var.enable_bedrock ? 1 : 0
}
