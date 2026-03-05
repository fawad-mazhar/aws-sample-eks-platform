variable "cluster_name" {
  type = string
}

variable "cluster_version" {
  type    = string
  default = "1.32"
}

variable "cluster_role_arn" {
  type        = string
  description = "ARN of the IAM role for the EKS cluster."
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "coredns_addon_version" {
  type    = string
  default = "v1.11.4-eksbuild.2"
}

variable "kube_proxy_addon_version" {
  type    = string
  default = "v1.32.0-eksbuild.2"
}

variable "cni_addon_version" {
  type    = string
  default = "v1.19.2-eksbuild.1"
}
