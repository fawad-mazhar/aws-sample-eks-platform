#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=bin/load-env.sh
. bin/load-env.sh

# Read-only AWS calls. Credentials: AWS_PROFILE (e.g. from .env) or the
# default credential chain.
K8S_VERSION="${K8S_VERSION:-1.37}"
REGION="${AWS_REGION:-eu-west-1}"
fail=0

if ! command -v aws > /dev/null 2>&1; then
	echo "Required command not found: aws" >&2
	exit 1
fi

check_addon() {
	local addon_name="$1"
	local addon_version="$2"
	local offered_version

	offered_version=$(
		aws eks describe-addon-versions \
			--region "$REGION" \
			--kubernetes-version "$K8S_VERSION" \
			--addon-name "$addon_name" \
			--query "addons[0].addonVersions[?addonVersion=='${addon_version}'].addonVersion" \
			--output text
	)

	if [ "$offered_version" = "$addon_version" ]; then
		echo "OK       $addon_name $addon_version"
	else
		echo "MISSING  $addon_name $addon_version (not offered for $K8S_VERSION)"
		fail=1
	fi
}

module_default() {
	local variable="$1"
	grep -A3 "variable \"$variable\"" aws/modules/eks-cluster/variables.tf |
		sed -n 's/.*default[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p'
}

environment_value() {
	local variable="$1"
	sed -n "s/.*${variable}[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
		aws/envs/eu-west-1/eks.tf
}

check_addon coredns "$(module_default coredns_addon_version)"
check_addon kube-proxy "$(module_default kube_proxy_addon_version)"
check_addon vpc-cni "$(module_default cni_addon_version)"
check_addon eks-pod-identity-agent "$(module_default pod_identity_agent_addon_version)"
check_addon aws-ebs-csi-driver "$(environment_value ebs_csi_addon_version)"
check_addon aws-efs-csi-driver "$(environment_value efs_csi_addon_version)"

exit "$fail"
