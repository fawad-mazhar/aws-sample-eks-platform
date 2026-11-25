module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "21.30.2"

  cluster_name = module.eks_cluster.cluster_name
  namespace    = "kube-system"

  # EKS Pod Identity (module default): the association binds the controller
  # role to kube-system/karpenter, so the ServiceAccount needs no role-arn
  # annotation and the manifests carry no account ID.
  create_pod_identity_association = true

  # Node role
  node_iam_role_use_name_prefix = false
  node_iam_role_name            = "${local.env_prefix}-karpenter-node"

  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = {
    Name = "${local.env_prefix}-karpenter"
  }
}

# Tag private subnets for Karpenter EC2NodeClass discovery
resource "aws_ec2_tag" "karpenter_subnet" {
  for_each = toset(local.private_subnet_ids)

  resource_id = each.value
  key         = "karpenter.sh/discovery"
  value       = local.eks_cluster_name
}

# Tag node security group for Karpenter EC2NodeClass discovery
resource "aws_ec2_tag" "karpenter_node_sg" {
  resource_id = module.eks_cluster.node_security_group_id
  key         = "karpenter.sh/discovery"
  value       = local.eks_cluster_name
}
