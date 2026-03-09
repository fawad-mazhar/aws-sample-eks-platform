module "eks_fargate_iam" {
  source = "../../modules/eks-fargate"

  env_prefix = local.env_prefix
}
