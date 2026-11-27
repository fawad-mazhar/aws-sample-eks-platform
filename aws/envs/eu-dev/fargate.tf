module "eks_fargate_iam" {
  source = "../../modules/eks-fargate"

  resource_prefix = local.resource_prefix
}
