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

module "cluster_autoscaler_pod_identity" {
  source = "../../modules/eks-pod-identity-iam"

  resource_prefix      = local.resource_prefix
  role_name            = "cluster-autoscaler"
  cluster_name         = module.eks_cluster.cluster_name
  namespace            = "autoscaling-system"
  service_account_name = "cluster-autoscaler"
  policy_json          = data.aws_iam_policy_document.cluster_autoscaler.json
}
