#!/usr/bin/env bash
# Carries Terraform outputs into the cluster. Flux has no access to Terraform
# state, so this is the one manual bridge between the two.
#
#   bin/cluster-config.sh vars [env]        print the Flux variables (KEY=VALUE)
#   bin/cluster-config.sh apply [env]       create/update cluster-information copies
#   bin/cluster-config.sh apply-flux [env]  create/update flux-system/cluster-vars
#
# cluster-information is read by controllers in gateway-system and
# autoscaling-system at runtime (configMapKeyRef). Copies are kept in
# kube-system for backward compatibility.
# cluster-vars is what Flux substitutes into ${VAR} placeholders
# (postBuild.substituteFrom). env defaults to eu-west-1.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=bin/load-env.sh
. bin/load-env.sh

command="${1:-}"
environment="${2:-eu-west-1}"
tf_dir="aws/envs/${environment}"
kgateway_overlay="flux/envs/${environment}/kgateway/kustomization.yaml"

usage() {
	sed -n '5,7s/^# *//p' "$0" >&2
	exit 2
}

# Prints a Terraform map output as KEY=VALUE lines. Needs an applied state.
output_lines() {
	local json
	if ! json="$(terraform -chdir="$tf_dir" output -json "$1")"; then
		echo "Terraform output '$1' unavailable in $tf_dir; run terraform apply first" >&2
		exit 1
	fi
	python3 -c 'import json, sys; [print(f"{k}={v}") for k, v in json.load(sys.stdin).items()]' <<< "$json"
}

# Fails early when the custom-domain component is enabled in git but no
# domain was given to Terraform: Flux would otherwise apply an empty hostname.
flux_vars() {
	local lines
	lines="$(output_lines flux_vars)"
	if grep -qE '^[[:space:]]*-[[:space:]]*custom-domain[[:space:]]*$' "$kgateway_overlay"; then
		if ! grep -qE '^APP_HOSTNAME=.+' <<< "$lines"; then
			echo "custom-domain is enabled in $kgateway_overlay but TF_VAR_domain_name is not set" >&2
			exit 1
		fi
	elif grep -qE '^APP_HOSTNAME=.+' <<< "$lines"; then
		echo "note: a domain is set in Terraform, but the custom-domain component is not enabled in $kgateway_overlay" >&2
	fi
	printf '%s\n' "$lines"
}

apply_configmap() {
	local name="$1" namespace="$2" lines="$3" line
	local args=()
	while IFS= read -r line; do
		args+=("--from-literal=${line}")
	done <<< "$lines"
	kubectl create configmap "$name" --namespace "$namespace" "${args[@]}" \
		--dry-run=client -o yaml | kubectl apply -f -
}

require_namespaces() {
	local namespace
	for namespace in "$@"; do
		if ! kubectl get namespace "$namespace" > /dev/null 2>&1; then
			echo "namespace '$namespace' not found; apply flux/base first" >&2
			exit 1
		fi
	done
}

# Outputs are captured in assignments first: a failing $(...) used directly as
# an argument would not stop the script under set -e.
case "$command" in
	vars)
		flux_vars
		;;
	apply)
		data="$(output_lines cluster_information)"
			require_namespaces kube-system gateway-system autoscaling-system
			apply_configmap cluster-information kube-system "$data"
			apply_configmap cluster-information gateway-system "$data"
			apply_configmap cluster-information autoscaling-system "$data"
		;;
	apply-flux)
		if ! kubectl get namespace flux-system > /dev/null 2>&1; then
			echo "flux-system namespace not found; install Flux first (kubectl apply -k flux/modules/flux-system/)" >&2
			exit 1
		fi
		data="$(flux_vars)"
		apply_configmap cluster-vars flux-system "$data"
		;;
	*)
		usage
		;;
esac
