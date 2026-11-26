#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

K8S_VERSION="${K8S_VERSION:-1.37.0}"
OUT="build/validate"
CONVERTER_VERSION="v0.8.0"
CONVERTER_URL="https://raw.githubusercontent.com/yannh/kubeconform/${CONVERTER_VERSION}/scripts/openapi2jsonschema.py"
VENV_PYTHON="build/venv/bin/python"
# Example values for the ${VAR} placeholders, so the gate needs no AWS account.
VARS_FILE="${VARS_FILE:-flux/envs/eu-west-1/cluster-vars.example.env}"
# Generated below: a kgateway overlay with the opt-in custom-domain component
# enabled when the checked-in overlay has not already enabled it.
CUSTOM_DOMAIN_OVERLAY="$OUT/overlays/kgateway-custom-domain"
KGATEWAY_OVERLAY="flux/envs/eu-west-1/kgateway/kustomization.yaml"
ENTRY_POINTS=("$@")

if [ "${#ENTRY_POINTS[@]}" -eq 0 ]; then
	ENTRY_POINTS=(
		flux/envs/eu-west-1/crds
		flux/envs/eu-west-1
		flux/envs/eu-west-1/flux-system
		flux/modules/flux-system
		flux/modules/keda-demo
	)
	if ! grep -qE '^[[:space:]]*-[[:space:]]*custom-domain[[:space:]]*$' "$KGATEWAY_OVERLAY"; then
		ENTRY_POINTS+=("$CUSTOM_DOMAIN_OVERLAY")
	fi
fi

for command in kustomize kubeconform pluto curl; do
	if ! command -v "$command" > /dev/null 2>&1; then
		echo "Required command not found: $command" >&2
		exit 1
	fi
done

if [ ! -x "$VENV_PYTHON" ]; then
	echo "Missing $VENV_PYTHON; create it with:" >&2
	echo "  python3 -m venv build/venv && build/venv/bin/pip install pyyaml" >&2
	exit 1
fi

if [ ! -f "$VARS_FILE" ]; then
	echo "Variables file not found: $VARS_FILE" >&2
	exit 1
fi

for entry_point in "${ENTRY_POINTS[@]}"; do
	if [ "$entry_point" != "$CUSTOM_DOMAIN_OVERLAY" ] && [ ! -d "$entry_point" ]; then
		echo "Kustomize entry point not found: $entry_point" >&2
		exit 1
	fi
done

rm -rf "$OUT"
mkdir -p "$OUT/rendered" "$OUT/schemas" "$OUT/schema-cache" "$CUSTOM_DOMAIN_OVERLAY"

printf '%s\n' \
	'apiVersion: kustomize.config.k8s.io/v1beta1' \
	'kind: Kustomization' \
	'resources:' \
	'  - ../../../../flux/envs/eu-west-1/kgateway' \
	'components:' \
	'  - ../../../../flux/envs/eu-west-1/kgateway/custom-domain' \
	> "$CUSTOM_DOMAIN_OVERLAY/kustomization.yaml"

for entry_point in "${ENTRY_POINTS[@]}"; do
	output="$OUT/rendered/$(printf '%s' "$entry_point" | tr '/' '_').yaml"
	case "$entry_point" in
		*flux-system)
			# Bootstrap manifests applied with kubectl; Flux never substitutes them.
			echo "Rendering $entry_point"
			kustomize build "$entry_point" > "$output"
			;;
		*)
			# Reconciled by Flux Kustomizations that substitute from cluster-vars.
			echo "Rendering $entry_point (variables from $VARS_FILE)"
			kustomize build "$entry_point" | python3 bin/flux-envsubst.py "$VARS_FILE" > "$output"
			;;
	esac
done

curl -fsSL "$CONVERTER_URL" -o "$OUT/openapi2jsonschema.py"
(
	cd "$OUT/schemas"
	FILENAME_FORMAT='{fullgroup}_{kind}_{version}' \
		../../venv/bin/python ../openapi2jsonschema.py ../rendered/*.yaml
)

echo "Validating Kubernetes manifests against $K8S_VERSION"
# The standalone-strict schema set omits CustomResourceDefinition; CR instances
# below still require a schema generated from the vendored CRDs.
kubeconform \
	-strict \
	-summary \
	-skip CustomResourceDefinition \
	-kubernetes-version "$K8S_VERSION" \
	-cache "$OUT/schema-cache" \
	-schema-location default \
	-schema-location "$OUT/schemas/{{ .Group }}_{{ .ResourceKind }}_{{ .ResourceAPIVersion }}.json" \
	"$OUT"/rendered/*.yaml

echo "Checking for removed or deprecated APIs at $K8S_VERSION"
pluto detect-files \
	-d "$OUT/rendered" \
	--target-versions "k8s=v${K8S_VERSION}" \
	-o wide
