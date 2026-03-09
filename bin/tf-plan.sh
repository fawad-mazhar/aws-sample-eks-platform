#!/usr/bin/env bash
set -e

function log() {
	echo "$(date "+%Y-%m-%d-%H:%M:%S"): ${1}"
}

REGION=${1:-eu-west-1}

cd "$(git rev-parse --show-toplevel)"

TF_DIR="aws/envs/${REGION}"
if [ ! -d "${TF_DIR}" ]; then
	echo "Terraform directory not found: ${TF_DIR}"
	exit 1
fi

log "Running terraform init and plan in ${TF_DIR}"
cd "${TF_DIR}"

terraform init -upgrade
terraform validate
terraform plan
