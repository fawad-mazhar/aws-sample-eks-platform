#!/usr/bin/env bash
# Builds a kustomize directory and fills in its ${VAR} placeholders the way
# Flux does after building it. Use it to apply without Flux (README Option B):
#
#   bin/render.sh flux/modules/sample-app | kubectl apply -f -
#
# Variables come from VARS_FILE (KEY=VALUE lines) when set, otherwise from the
# environment's Terraform outputs (`bin/cluster-config.sh vars`).
set -euo pipefail

if [ "$#" -ne 1 ] || [ ! -d "$1" ]; then
	echo "usage: bin/render.sh <kustomize-dir>" >&2
	exit 2
fi

root="$(git rev-parse --show-toplevel)"

if [ -n "${VARS_FILE:-}" ]; then
	variables="$(cat "$VARS_FILE")"
else
	variables="$("$root/bin/cluster-config.sh" vars)"
fi

if command -v kustomize > /dev/null 2>&1; then
	rendered="$(kustomize build "$1")"
else
	rendered="$(kubectl kustomize "$1")"
fi

printf '%s\n' "$rendered" | python3 "$root/bin/flux-envsubst.py" <(printf '%s\n' "$variables")
