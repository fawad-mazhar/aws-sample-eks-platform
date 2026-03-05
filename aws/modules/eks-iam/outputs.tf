output "cluster_role_arn" {
  value = aws_iam_role.cluster.arn
}

output "cluster_role_name" {
  value = aws_iam_role.cluster.name
}

output "node_group_role_arn" {
  value = aws_iam_role.node_group.arn
}

output "node_group_role_name" {
  value = aws_iam_role.node_group.name
}
