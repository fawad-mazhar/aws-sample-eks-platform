terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.73.0"
    }
  }
}

resource "aws_ecr_repository" "this" {
  name                 = var.repository_name
  image_tag_mutability = "IMMUTABLE"
  force_delete         = var.force_delete

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Name = var.repository_name
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

resource "terraform_data" "docker_build_push" {
  triggers_replace = {
    source_hash = sha1(join("", [for f in fileset(var.source_path, "**") : filesha1("${var.source_path}/${f}")]))
    image_tag   = var.image_tag
    platforms   = join(",", var.platforms)
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      docker_config="$(mktemp -d)"
      real_docker_config="$${DOCKER_CONFIG:-$${HOME}/.docker}"
      cleanup() {
        rm -rf -- "$docker_config"
      }
      trap cleanup EXIT

      mkdir -p "$docker_config"
      if [ -d "$real_docker_config" ]; then
        for item in cli-plugins contexts buildx; do
          if [ -e "$real_docker_config/$item" ]; then
            ln -s "$real_docker_config/$item" "$docker_config/$item"
          fi
        done
        if [ -f "$real_docker_config/currentContext" ]; then
          cp "$real_docker_config/currentContext" "$docker_config/currentContext"
        fi
        if [ -f "$real_docker_config/config.json" ]; then
          cp "$real_docker_config/config.json" "$docker_config/config.json"
        fi
      fi

      aws ecr get-login-password --region ${var.region} \
        | docker --config "$docker_config" login --username AWS --password-stdin ${split("/", aws_ecr_repository.this.repository_url)[0]}
      DOCKER_CONFIG="$docker_config" docker buildx build \
        --platform ${join(",", var.platforms)} \
        --provenance=false \
        -t ${aws_ecr_repository.this.repository_url}:${var.image_tag} \
        --push ${abspath(var.source_path)}
    EOT
  }
}
