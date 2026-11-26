variable "region" {
  type = string

  validation {
    condition     = var.region == "eu-west-1"
    error_message = "Region must be eu-west-1."
  }
}

variable "environment" {
  type        = string
  default     = "eu-dev"
  description = "Short resource tag in <geography>-<stage> form, e.g. eu-dev, eu-prd, us-dev or us-stg. Resources use <environment>-<resource>."

  validation {
    condition     = can(regex("^[a-z][a-z0-9]*-[a-z][a-z0-9-]*$", var.environment))
    error_message = "environment must use lowercase <geography>-<stage> format, such as eu-dev, eu-prd, us-dev or us-stg."
  }
}

variable "vpc_id" {
  type        = string
  description = "ID of the existing VPC to use for EKS. Set TF_VAR_vpc_id in .env."
}

variable "private_subnet_ids" {
  type        = list(string)
  default     = null
  description = "Optional. Private subnets (in vpc_id, at least two AZs) for the control plane, nodes, Fargate and EFS. Unset: every subnet in vpc_id with map-public-ip-on-launch=false. Set TF_VAR_private_subnet_ids in .env."

  validation {
    condition     = var.private_subnet_ids == null || alltrue([for id in coalesce(var.private_subnet_ids, []) : can(regex("^subnet-[0-9a-f]+$", id))])
    error_message = "private_subnet_ids must be a list of subnet IDs, e.g. [\"subnet-0123456789abcdef0\", \"subnet-0fedcba9876543210\"]."
  }
}

variable "alb_deployed" {
  type        = bool
  default     = false
  description = "Set to true after ALB controller and Ingress are deployed, to create the Route53 ALB alias record."
}

# --- Optional custom domain ---------------------------------------------------
# Leave domain_name unset to deploy without DNS or HTTPS: the sample app is then
# served over HTTP on the ALB's own DNS name.

variable "domain_name" {
  type        = string
  default     = null
  description = "Optional. Route53 hosted zone name, e.g. example.com. Set TF_VAR_domain_name in .env."
}

variable "route53_zone_id" {
  type        = string
  default     = null
  description = "Optional. Existing public Route53 hosted zone ID for domain_name. Leave unset to create a new hosted zone."

  validation {
    condition     = var.route53_zone_id == null || can(regex("^Z[A-Z0-9]+$", var.route53_zone_id))
    error_message = "route53_zone_id must be a Route53 hosted zone ID such as Z1234567890ABC."
  }
}

variable "app_subdomain" {
  type        = string
  default     = "books"
  description = "Subdomain of domain_name that serves the sample app."
}

variable "acm_certificate_arn" {
  type        = string
  default     = null
  description = "ACM certificate for the app hostname, used by the HTTPS listener. Required when domain_name is set."

  validation {
    condition     = var.acm_certificate_arn == null || can(regex("^arn:aws:acm:", var.acm_certificate_arn))
    error_message = "acm_certificate_arn must be an ACM certificate ARN."
  }
}
