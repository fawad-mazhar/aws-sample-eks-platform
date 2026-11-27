#!/usr/bin/env bash
# Builds the environment's full manifest set with the ${VAR} placeholders
# filled in (bin/render.sh), i.e. what would actually be applied. Variables
# come from the environment's Terraform outputs, or from VARS_FILE, e.g.
#   VARS_FILE=flux/envs/eu-dev/cluster-vars.example.env bin/build.sh eu-dev
set -e

function log() {
	echo "$(date "+%Y-%m-%d-%H:%M:%S"): ${1}"
}

ENV=${1}
if [ -z "${ENV}" ]; then
	echo "Environment name arg missing"
	echo "Usage: bin/build.sh <env>"
	echo "Example: bin/build.sh eu-dev"
	exit 1
fi

cd "$(git rev-parse --show-toplevel)"

DIR="build/${ENV}"
rm -fR "${DIR}"
log "env: ${ENV}, dir: ${DIR}"

mkdir -p "${DIR}"
# Render to a temporary name so a failed render leaves no artifact behind.
ENVIRONMENT="${ENV}" bin/render.sh "./flux/envs/${ENV}" > "${DIR}/build.yaml.partial"
mv "${DIR}/build.yaml.partial" "${DIR}/build.yaml"

log "Build artifact: ${DIR}/build.yaml"
kustomize cfg count "${DIR}"

sha1sum "${DIR}/build.yaml" > "${DIR}/build.yaml.sha" 2>/dev/null || shasum "${DIR}/build.yaml" > "${DIR}/build.yaml.sha"

log "Final build artifact:"
cat "${DIR}/build.yaml.sha"
