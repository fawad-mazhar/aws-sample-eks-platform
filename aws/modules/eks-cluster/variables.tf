variable "cluster_name" {
  type = string
}

variable "cluster_version" {
  type    = string
  default = "1.37"
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
  default = "v1.14.7-eksbuild.35"
}

variable "kube_proxy_addon_version" {
  type    = string
  default = "v1.37.0-eksbuild.39"
}

variable "cni_addon_version" {
  type    = string
  default = "v1.22.4-eksbuild.14"
}

variable "pod_identity_agent_addon_version" {
  type    = string
  default = "v1.5.0-eksbuild.3"
}

variable "node_group_role_arn" {
  type        = string
  description = "ARN of the IAM role for EKS managed node groups."
  default     = ""
}

variable "eks_managed_node_groups" {
  type        = any
  description = "Map of EKS managed node group configurations."
  default     = {}
}

variable "fargate_profiles" {
  type        = any
  description = "Map of Fargate profile configurations."
  default     = {}
}

variable "fargate_role_arn" {
  type        = string
  description = "ARN of the IAM role for EKS Fargate profiles."
  default     = ""
}

variable "ebs_csi_addon_version" {
  type        = string
  default     = ""
  description = "Version of the EBS CSI driver addon. Leave empty to skip."
}

variable "ebs_csi_addon_role_arn" {
  type        = string
  default     = ""
  description = "IRSA role ARN for the EBS CSI driver. Required when ebs_csi_addon_version is set."
}

variable "efs_csi_addon_version" {
  type        = string
  default     = ""
  description = "Version of the EFS CSI driver addon. Leave empty to skip."
}

variable "efs_csi_addon_role_arn" {
  type        = string
  default     = ""
  description = "IRSA role ARN for the EFS CSI driver. Required when efs_csi_addon_version is set."
}
