data "aws_iam_policy" "ebs_csi_driver" {
  arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

module "ebs_csi_irsa" {
  source = "../../modules/eks-oidc-iam"

  env_prefix           = local.env_prefix
  role_name            = "ebs-csi"
  oidc_provider_arn    = module.eks_cluster.oidc_provider_arn
  oidc_issuer          = module.eks_cluster.oidc_provider
  namespace            = "kube-system"
  service_account_name = "ebs-csi-controller-sa"
  policy_json          = data.aws_iam_policy.ebs_csi_driver.policy
}
