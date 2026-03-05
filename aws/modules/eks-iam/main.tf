terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.31.0"
    }
  }
}

# --- EKS Cluster Role ---

data "aws_iam_policy_document" "cluster_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.env_prefix}-eks-cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume_role.json

  tags = {
    Name = "${var.env_prefix}-eks-cluster"
  }
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# --- EKS Node Group Role ---

data "aws_iam_policy_document" "node_group_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node_group" {
  name               = "${var.env_prefix}-eks-node-group"
  assume_role_policy = data.aws_iam_policy_document.node_group_assume_role.json

  tags = {
    Name = "${var.env_prefix}-eks-node-group"
  }
}

resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "node_ssm" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "node_cloudwatch" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}
