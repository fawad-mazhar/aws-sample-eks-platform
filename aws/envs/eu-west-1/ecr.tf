locals {
  ecr_repositories = {
    nats = {
      image_tag = "2.12.3"
    }
    nats-box = {
      image_tag = "0.19.2"
    }
    kgateway-discovery = {
      image_tag = "1.22.8"
      platforms = ["linux/amd64"]
    }
    kgateway-envoy = {
      image_tag = "1.22.8"
      platforms = ["linux/amd64"]
    }
    kgateway-gloo = {
      image_tag = "1.22.8"
      platforms = ["linux/amd64"]
    }
    kgateway-kubectl = {
      image_tag = "1.22.8"
    }
    keda = {
      image_tag = "2.21.1"
    }
    keda-metrics-apiserver = {
      image_tag = "2.21.1"
    }
    keda-admission-webhooks = {
      image_tag = "2.21.1"
    }
    prometheus = {
      image_tag = "v3.9.1"
    }
    prometheus-config-reloader = {
      image_tag = "v0.88.0"
    }
    prometheus-nats-exporter = {
      image_tag = "0.18.0"
    }
    sealed-secrets-controller = {
      image_tag = "0.34.0"
    }
    cert-manager-controller = {
      image_tag = "1.21.3"
    }
    cert-manager-webhook = {
      image_tag = "1.21.3"
    }
    cert-manager-cainjector = {
      image_tag = "1.21.3"
    }
    sample-app = {
      image_tag = "1.0.0"
    }
    cluster-autoscaler = {
      image_tag = "v1.37.0"
    }
    karpenter = {
      image_tag = "1.15.2"
    }
    garage = {
      image_tag = "v2.3.0"
    }
  }
}

module "ecr" {
  source   = "../../modules/ecr"
  for_each = local.ecr_repositories

  repository_name = "${local.env_prefix}/${each.key}"
  source_path     = "${path.module}/../../../applications/${each.key}"
  image_tag       = each.value.image_tag
  platforms       = try(each.value.platforms, ["linux/amd64", "linux/arm64"])
  region          = var.region
  aws_profile     = "nlaclassic"
}
