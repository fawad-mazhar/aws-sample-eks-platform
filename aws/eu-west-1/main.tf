terraform {
  required_version = "~> 1.14.0"

  backend "local" {
    path = "terraform.tfstate"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.31.0"
    }
  }
}

provider "aws" {
  region  = var.region
  profile = "nlaclassic"

  default_tags {
    tags = {
      environment  = var.environment
      account-name = var.account_name
    }
  }
}
