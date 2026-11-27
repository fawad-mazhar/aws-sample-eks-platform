#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

ENVIRONMENT="${1:-eu-dev}"
TF_DIR="aws/envs/${ENVIRONMENT}"

if [ ! -d "$TF_DIR" ]; then
	echo "Terraform directory not found: $TF_DIR" >&2
	exit 1
fi

for command in terraform git; do
	if ! command -v "$command" > /dev/null 2>&1; then
		echo "Required command not found: $command" >&2
		exit 1
	fi
done

terraform fmt -check -recursive -diff aws/

cd "$TF_DIR"
terraform init -backend=false -input=false -upgrade > /dev/null
terraform validate
