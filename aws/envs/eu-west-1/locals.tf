locals {
  env_prefix       = "${var.account_name}-${var.region}"
  eks_cluster_name = "${local.env_prefix}-eks"
}
