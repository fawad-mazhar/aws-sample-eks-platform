variable "account_name" {
  type        = string
  description = "Resource name prefix, e.g. demo gives demo-eu-west-1-eks. Set TF_VAR_account_name in .env."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.account_name))
    error_message = "account_name must be 2-21 lowercase letters, digits or hyphens, starting with a letter."
  }
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
  description = "ID of the existing VPC to use for EKS. Set TF_VAR_vpc_id in .env."
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
  description = "Optional. Route53 hosted zone to create, e.g. example.com. Set TF_VAR_domain_name in .env."
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
