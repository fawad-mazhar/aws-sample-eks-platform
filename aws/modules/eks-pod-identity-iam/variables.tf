variable "resource_prefix" {
  type        = string
  description = "Short environment tag for resource naming (e.g. eu-dev)."
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
