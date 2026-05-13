data "aws_iam_policy_document" "cluster_autoscaler" {
  statement {
    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeLaunchConfigurations",
      "autoscaling:DescribeScalingActivities",
      "autoscaling:DescribeTags",
      "ec2:DescribeImages",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplateVersions",
      "ec2:GetInstanceTypesFromInstanceRequirements",
      "eks:DescribeNodegroup",
    ]
    resources = ["*"]
  }

  statement {
    actions = [
      "autoscaling:SetDesiredCapacity",
      "autoscaling:TerminateInstanceInAutoScalingGroup",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/k8s.io/cluster-autoscaler/enabled"
      values   = ["true"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/k8s.io/cluster-autoscaler/${local.eks_cluster_name}"
      values   = ["owned"]
    }
  }
}

module "cluster_autoscaler_irsa" {
  source = "../../modules/eks-oidc-iam"

  env_prefix           = local.env_prefix
  role_name            = "cluster-autoscaler"
  oidc_provider_arn    = module.eks_cluster.oidc_provider_arn
  oidc_issuer          = module.eks_cluster.oidc_provider
  namespace            = "kube-system"
  service_account_name = "cluster-autoscaler"
  policy_json          = data.aws_iam_policy_document.cluster_autoscaler.json
}
