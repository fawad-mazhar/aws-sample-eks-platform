module "eks_iam" {
  source = "../../modules/eks-iam"

  resource_prefix = local.resource_prefix
}
