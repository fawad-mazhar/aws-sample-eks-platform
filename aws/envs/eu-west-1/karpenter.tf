module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "21.30.2"

  cluster_name = module.eks_cluster.cluster_name
  namespace    = "autoscaling-system"

  # EKS Pod Identity (module default): the association binds the controller
  # role to autoscaling-system/karpenter, so the ServiceAccount needs no
  # role-arn annotation and the manifests carry no account ID.
  create_pod_identity_association = true
  enable_inline_policy            = true
  iam_role_name                   = "${local.resource_prefix}-karpenter-controller"
  iam_role_use_name_prefix        = false
  iam_policy_name                 = "${local.resource_prefix}-karpenter-controller"
  iam_policy_use_name_prefix      = false

  iam_role_tags = {
    Name = "${local.resource_prefix}-karpenter-controller"
  }

  # Node role
  node_iam_role_use_name_prefix = false
  node_iam_role_name            = "${local.resource_prefix}-karpenter-node"

  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  node_iam_role_tags = {
    Name = "${local.resource_prefix}-karpenter-node"
  }

  queue_name       = "${local.resource_prefix}-karpenter-interruption-queue"
  rule_name_prefix = "${local.resource_prefix}-karpenter-"

  tags = {
    Name = "${local.resource_prefix}-karpenter"
  }
}

# Tag private subnets for Karpenter EC2NodeClass discovery
resource "aws_ec2_tag" "karpenter_subnet" {
  for_each = toset(local.private_subnet_ids)

  resource_id = each.value
  key         = "karpenter.sh/discovery"
  value       = local.eks_cluster_name
}

removed {
  from = aws_ec2_tag.karpenter_node_sg

  lifecycle {
    destroy = false
  }
}
