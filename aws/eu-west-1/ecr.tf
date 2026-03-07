locals {
  ecr_repositories = {
    nats = {
      image_tag = "2.12.3"
    }
    nats-box = {
      image_tag = "0.19.2"
    }
  }
}

module "ecr" {
  source   = "../modules/ecr"
  for_each = local.ecr_repositories

  repository_name = "${local.env_prefix}/${each.key}"
  source_path     = "${path.module}/../../applications/${each.key}"
  image_tag       = each.value.image_tag
  region          = var.region
  aws_profile     = "nlaclassic"
}
