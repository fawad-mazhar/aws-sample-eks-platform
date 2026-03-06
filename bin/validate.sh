#!/usr/bin/env bash
set -e

function log() {
	echo "$(date "+%Y-%m-%d-%H:%M:%S"): ${1}"
}

INPUT=${1}
if [ -z "${INPUT}" ]; then
	echo "Input arg missing (path to file or directory)"
	echo "Usage: bin/validate.sh <path>"
	echo "Example: bin/validate.sh flux/envs/dev"
	exit 1
fi

cd "$(git rev-parse --show-toplevel)"

# Check if kubeconform is available, fall back to kustomize build dry-run
if command -v kubeconform &> /dev/null; then
	VALIDATOR="kubeconform"
else
	VALIDATOR="kustomize"
	log "kubeconform not found, falling back to kustomize build validation"
fi

if [ -f "${INPUT}" ]; then
	log "Validating file ${INPUT}"
	if [ "${VALIDATOR}" = "kubeconform" ]; then
		kubeconform -ignore-missing-schemas -strict "${INPUT}"
	else
		log "File validation requires kubeconform. Skipping."
		exit 0
	fi
	exit $?
fi

if [ -d "${INPUT}" ]; then
	log "Building and validating path ${INPUT}"
	if [ "${VALIDATOR}" = "kubeconform" ]; then
		kustomize build "${INPUT}" | kubeconform -ignore-missing-schemas -strict
	else
		kustomize build "${INPUT}" > /dev/null
	fi
	log "Validation passed"
	exit $?
fi

log "${INPUT} is not a file nor directory"
exit 1
