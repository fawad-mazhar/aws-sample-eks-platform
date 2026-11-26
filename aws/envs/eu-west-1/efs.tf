data "aws_iam_policy" "efs_csi_driver" {
  arn = "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
}

module "efs_csi_irsa" {
  source = "../../modules/eks-oidc-iam"

  resource_prefix      = local.resource_prefix
  role_name            = "efs-csi"
  oidc_provider_arn    = module.eks_cluster.oidc_provider_arn
  oidc_issuer          = module.eks_cluster.oidc_provider
  namespace            = "kube-system"
  service_account_name = "efs-csi-controller-sa"
  policy_json          = data.aws_iam_policy.efs_csi_driver.policy
}

resource "aws_efs_file_system" "this" {
  encrypted = true

  lifecycle_policy {
    transition_to_ia = "AFTER_7_DAYS"
  }

  tags = {
    Name = "${local.resource_prefix}-efs"
  }
}

resource "aws_security_group" "efs" {
  name_prefix = "${local.resource_prefix}-efs-"
  description = "Allow NFS access from EKS cluster"
  vpc_id      = data.aws_vpc.this.id

  tags = {
    Name = "${local.resource_prefix}-efs"
  }
}

resource "aws_vpc_security_group_ingress_rule" "efs_nfs" {
  security_group_id            = aws_security_group.efs.id
  description                  = "NFS from EKS nodes"
  from_port                    = 2049
  to_port                      = 2049
  ip_protocol                  = "tcp"
  referenced_security_group_id = module.eks_cluster.node_security_group_id
}

# EFS allows one mount target per Availability Zone, so use one private subnet
# in each AZ (the lowest ID when an AZ has several). Pods in other subnets of
# the same AZ reach it through the VPC's local routing.
resource "aws_efs_mount_target" "this" {
  for_each = { for az, ids in local.private_subnets_by_az : az => sort(ids)[0] }

  file_system_id  = aws_efs_file_system.this.id
  subnet_id       = each.value
  security_groups = [aws_security_group.efs.id]
}
