#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=bin/load-env.sh
. bin/load-env.sh

ENVIRONMENT="${1:-eu-west-1}"
REGION="${AWS_REGION:-eu-west-1}"

bin/tf-validate.sh "$ENVIRONMENT"
bin/validate.sh
bin/check-images.sh

# Opt-in: the add-on check calls AWS (read-only), using AWS_PROFILE from .env
# or the default credential chain. Without credentials it is skipped.
if aws sts get-caller-identity --region "$REGION" > /dev/null 2>&1; then
	bin/check-addons.sh
else
	echo "skip: check-addons (no AWS credentials; set AWS_PROFILE in .env to enable)"
fi
