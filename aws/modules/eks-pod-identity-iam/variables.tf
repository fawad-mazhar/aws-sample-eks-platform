variable "env_prefix" {
  type        = string
  description = "Environment prefix for resource naming (e.g. demo-eu-west-1)."
}

variable "role_name" {
  type = string
}

variable "cluster_name" {
  type = string
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
