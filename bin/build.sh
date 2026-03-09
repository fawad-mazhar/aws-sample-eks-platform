#!/usr/bin/env bash
set -e

function log() {
	echo "$(date "+%Y-%m-%d-%H:%M:%S"): ${1}"
}

ENV=${1}
if [ -z "${ENV}" ]; then
	echo "Environment name arg missing"
	echo "Usage: bin/build.sh <env>"
	echo "Example: bin/build.sh eu-west-1"
	exit 1
fi

cd "$(git rev-parse --show-toplevel)"

DIR="build/${ENV}"
rm -fR "${DIR}"
log "env: ${ENV}, dir: ${DIR}"

mkdir -p "${DIR}"
kustomize build "./flux/envs/${ENV}" > "${DIR}/build.yaml"

log "Build artifact: ${DIR}/build.yaml"
kustomize cfg count "${DIR}"

sha1sum "${DIR}/build.yaml" > "${DIR}/build.yaml.sha" 2>/dev/null || shasum "${DIR}/build.yaml" > "${DIR}/build.yaml.sha"

log "Final build artifact:"
cat "${DIR}/build.yaml.sha"
