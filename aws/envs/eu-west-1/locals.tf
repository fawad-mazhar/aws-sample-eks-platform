data "aws_caller_identity" "current" {}

locals {
  env_prefix       = "${var.account_name}-${var.region}"
  eks_cluster_name = "${local.env_prefix}-eks"

  custom_domain = var.domain_name != null
  app_hostname  = local.custom_domain ? "${var.app_subdomain}.${var.domain_name}" : ""

  ecr_registry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}
