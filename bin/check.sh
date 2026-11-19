#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

ENVIRONMENT="${1:-eu-west-1}"
PROFILE="${AWS_PROFILE:-nlaclassic}"
REGION="${AWS_REGION:-eu-west-1}"

bin/tf-validate.sh "$ENVIRONMENT"
bin/validate.sh
bin/check-images.sh

if aws sts get-caller-identity --profile "$PROFILE" --region "$REGION" > /dev/null 2>&1; then
	bin/check-addons.sh
else
	echo "skip: check-addons (AWS credentials unavailable for profile $PROFILE)"
fi
