# IRSA trust policy for Karpenter controller (overrides default Pod Identity)
data "aws_iam_policy_document" "karpenter_irsa_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks_cluster.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks_cluster.oidc_provider}:sub"
      values   = ["system:serviceaccount:kube-system:karpenter"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks_cluster.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "21.15.1"

  cluster_name = module.eks_cluster.cluster_name
  namespace    = "kube-system"

  # Use IRSA instead of Pod Identity
  create_pod_identity_association          = false
  iam_role_override_assume_policy_documents = [data.aws_iam_policy_document.karpenter_irsa_assume.json]

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
  for_each = toset(data.aws_subnets.private.ids)

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
