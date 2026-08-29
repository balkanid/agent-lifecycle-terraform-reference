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
  region = var.aws_region
  # Gate-only runs (enable_bedrock=false) never call AWS APIs; dummy creds avoid
  # credential chain lookup on GitHub-hosted runners with no AWS secrets configured.
  access_key                  = var.enable_bedrock ? null : "unused"
  secret_key                  = var.enable_bedrock ? null : "unused"
  skip_credentials_validation = !var.enable_bedrock
  skip_requesting_account_id  = !var.enable_bedrock
  skip_metadata_api_check     = true
}

data "aws_caller_identity" "current" {
  count = var.enable_bedrock ? 1 : 0
}
