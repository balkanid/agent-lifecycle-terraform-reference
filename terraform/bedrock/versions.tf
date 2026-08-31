terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.46.0"
    }
  }
}

provider "aws" {
  region                      = var.aws_region
  profile                     = "terraform"
  shared_config_files         = []
  shared_credentials_files    = [var.aws_credentials_file]
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
}
