terraform {
  required_version = ">= 1.12.1"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.49.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.3.0"
    }
  }

  backend "s3" {
    bucket  = "inbound-carrier-tofu-state"
    key     = "inbound-carrier-sales/terraform.tfstate"
    region  = "us-east-1"
    encrypt = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "inbound-carrier-sales"
      Environment = var.environment
      ManagedBy   = "opentofu"
    }
  }
}
