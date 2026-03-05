module "eks_cluster" {
  source = "../modules/eks-cluster"

  cluster_name     = local.eks_cluster_name
  cluster_role_arn = module.eks_iam.cluster_role_arn
  vpc_id           = data.aws_vpc.this.id
  private_subnet_ids = data.aws_subnets.private.ids
}
