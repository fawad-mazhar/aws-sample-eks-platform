variable "resource_prefix" {
  type        = string
  description = "Short environment tag for resource naming (e.g. eu-dev)."
}

variable "role_name" {
  type = string
}

variable "oidc_provider_arn" {
  type = string
}

variable "oidc_issuer" {
  type        = string
  description = "OIDC issuer URL without https:// prefix."
}

variable "namespace" {
  type = string
}

variable "service_account_name" {
  type = string
}

variable "policy_json" {
  type = string
}
