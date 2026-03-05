output "cluster_role_arn" {
  value = module.eks_iam.cluster_role_arn
}

output "node_group_role_arn" {
  value = module.eks_iam.node_group_role_arn
}

output "vpc_id" {
  value = data.aws_vpc.this.id
}

output "private_subnet_ids" {
  value = data.aws_subnets.private.ids
}

output "public_subnet_ids" {
  value = data.aws_subnets.public.ids
}
