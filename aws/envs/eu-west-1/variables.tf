variable "account_name" {
  type = string
}

variable "region" {
  type = string

  validation {
    condition     = var.region == "eu-west-1"
    error_message = "Region must be eu-west-1."
  }
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "vpc_id" {
  type        = string
  description = "ID of the existing VPC to use for EKS."
}

variable "alb_deployed" {
  type        = bool
  default     = false
  description = "Set to true after ALB controller and Ingress are deployed, to create Route53 ALB alias record."
}

