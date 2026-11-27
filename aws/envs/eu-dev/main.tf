terraform {
  required_version = "~> 1.14.0"

  backend "local" {
    path = "terraform.tfstate"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.73.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      environment = var.environment
      managed-by  = "terraform"
      project     = "aws-sample-eks-platform"
      region      = var.region
    }
  }
}
