data "aws_vpc" "this" {
  id = var.vpc_id
}

# Private subnets: var.private_subnet_ids when set, otherwise every subnet in
# the VPC that doesn't auto-assign public IPs. The guess picks up any such
# subnet, including isolated (database, transit) tiers and public subnets that
# have auto-assign turned off, so pin the list when the VPC has more than one
# kind of subnet without public IPs.
data "aws_subnets" "private" {
  count = var.private_subnet_ids == null ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }

  filter {
    name   = "map-public-ip-on-launch"
    values = ["false"]
  }
}

data "aws_subnet" "private" {
  for_each = toset(local.private_subnet_ids)

  id = each.value

  lifecycle {
    postcondition {
      condition     = self.vpc_id == var.vpc_id
      error_message = "Subnet ${self.id} is in ${self.vpc_id}, not in vpc_id (${var.vpc_id})."
    }
  }
}

# Only used for the public_subnet_ids output. The ALB controller finds the
# public subnets for the internet-facing ALB on its own: subnets tagged
# kubernetes.io/role/elb, or, if none are tagged, subnets whose route table
# has a route to an internet gateway.
data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }

  filter {
    name   = "map-public-ip-on-launch"
    values = ["true"]
  }
}
