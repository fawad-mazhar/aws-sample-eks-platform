#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

K8S_VERSION="${K8S_VERSION:-1.37.0}"
OUT="build/validate"
CONVERTER_VERSION="v0.8.0"
CONVERTER_URL="https://raw.githubusercontent.com/yannh/kubeconform/${CONVERTER_VERSION}/scripts/openapi2jsonschema.py"
VENV_PYTHON="build/venv/bin/python"
ENTRY_POINTS=("$@")

if [ "${#ENTRY_POINTS[@]}" -eq 0 ]; then
	ENTRY_POINTS=(
		flux/envs/eu-west-1/crds
		flux/envs/eu-west-1
		flux/envs/eu-west-1/flux-system
		flux/modules/flux-system
		flux/modules/keda-demo
	)
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

for entry_point in "${ENTRY_POINTS[@]}"; do
	if [ ! -d "$entry_point" ]; then
		echo "Kustomize entry point not found: $entry_point" >&2
		exit 1
	fi
done

rm -rf "$OUT"
mkdir -p "$OUT/rendered" "$OUT/schemas" "$OUT/schema-cache"

for entry_point in "${ENTRY_POINTS[@]}"; do
	output="$OUT/rendered/$(printf '%s' "$entry_point" | tr '/' '_').yaml"
	echo "Rendering $entry_point"
	kustomize build "$entry_point" > "$output"
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
