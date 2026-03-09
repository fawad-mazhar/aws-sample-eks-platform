module "eks_iam" {
  source = "../../modules/eks-iam"

  env_prefix = local.env_prefix
}
