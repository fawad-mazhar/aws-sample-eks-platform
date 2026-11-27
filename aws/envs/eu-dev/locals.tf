data "aws_caller_identity" "current" {}

locals {
  resource_prefix  = var.environment
  eks_cluster_name = "${local.resource_prefix}-eks"

  custom_domain = var.domain_name != null
  app_hostname  = local.custom_domain ? "${var.app_subdomain}.${var.domain_name}" : ""

  ecr_registry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"

  # See data.tf. Used for the control plane ENIs, managed node groups, Fargate
  # profiles, Karpenter subnet discovery and EFS mount targets.
  private_subnet_ids = var.private_subnet_ids != null ? var.private_subnet_ids : data.aws_subnets.private[0].ids

  # AZ => subnet IDs in that AZ.
  private_subnets_by_az = {
    for s in data.aws_subnet.private : s.availability_zone => s.id...
  }
}
