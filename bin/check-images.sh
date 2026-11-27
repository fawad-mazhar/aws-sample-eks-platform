#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

ECR_TF="aws/envs/eu-dev/ecr.tf"
RENDERED_DIR="build/validate/rendered"
fail=0

DEFAULT_ECR_PLATFORMS=$(
	sed -nE 's/^[[:space:]]*platforms[[:space:]]*=[[:space:]]*try\(each\.value\.platforms,[[:space:]]*\[(.*)\]\).*/\1/p' \
		"$ECR_TF" | tr -d '"[:space:]'
)

if ! command -v docker > /dev/null 2>&1; then
	echo "Required command not found: docker" >&2
	exit 1
fi

if [ -z "$DEFAULT_ECR_PLATFORMS" ]; then
	echo "Could not read the default ECR platforms from $ECR_TF" >&2
	exit 1
fi

if [ ! -d "$RENDERED_DIR" ]; then
	echo "Rendered manifests not found; run bin/validate.sh first" >&2
	exit 1
fi

repository_platforms() {
	local repository="$1"

	awk -v repository="$repository" -v default_platforms="$DEFAULT_ECR_PLATFORMS" '
		$1 == repository && $2 == "=" && $3 == "{" {
			in_repository = 1
			found_repository = 1
			next
		}
		in_repository && $1 == "platforms" {
			line = $0
			sub(/^[^[]*\[/, "", line)
			sub(/\].*$/, "", line)
			gsub(/["[:space:]]/, "", line)
			print line
			found_platforms = 1
			exit
		}
		in_repository && $1 == "}" { exit }
		END {
			if (found_repository && !found_platforms) {
				print default_platforms
			}
		}
	' "$ECR_TF"
}

while IFS= read -r dockerfile; do
	repository="$(basename "$(dirname "$dockerfile")")"
	source_images=()
	while IFS= read -r source_image; do
		if [ -n "$source_image" ]; then
			source_images+=("$source_image")
		fi
	done < <(awk '$1 == "FROM" { print $2 }' "$dockerfile")

	if [ "${#source_images[@]}" -eq 0 ]; then
		echo "NO FROM  $dockerfile"
		fail=1
		continue
	fi

	requires_multiarch=false
	if grep -q '# MULTIARCH' "$dockerfile"; then
		requires_multiarch=true
	fi

	platforms=$(repository_platforms "$repository")
	if [ -z "$platforms" ]; then
		echo "NO ECR ENTRY  $repository ($dockerfile)"
		fail=1
		continue
	fi

	normalized_platforms=$(tr ',' '\n' <<< "$platforms" | sort | paste -sd, -)
	if $requires_multiarch; then
		if [ "$normalized_platforms" != "linux/amd64,linux/arm64" ]; then
			echo "PLATFORM MISMATCH  $repository has # MULTIARCH but ecr.tf builds $platforms"
			fail=1
		fi
	else
		if [ "$normalized_platforms" != "linux/amd64" ]; then
			echo "PLATFORM MISMATCH  $repository is missing # MULTIARCH for $platforms"
			fail=1
		fi
	fi

	for source_image in "${source_images[@]}"; do
		if ! inspect_output=$(docker buildx imagetools inspect "$source_image" 2>&1); then
			echo "MISSING  $source_image ($dockerfile)"
			fail=1
			continue
		fi

		if $requires_multiarch; then
			for platform in linux/amd64 linux/arm64; do
				if ! grep -q "Platform: *${platform}" <<< "$inspect_output"; then
					echo "NO ${platform}  $source_image ($dockerfile)"
					fail=1
				fi
			done
		fi
	done
done < <(find applications -mindepth 2 -maxdepth 2 -name Dockerfile -print | sort)

manifest_images=()
while IFS= read -r manifest_image; do
	if [ -n "$manifest_image" ]; then
		manifest_images+=("$manifest_image")
	fi
done < <(
	sed -nE 's/^[[:space:]]*(-[[:space:]]+)?image:[[:space:]]*"?([^"[:space:]]+)"?[[:space:]]*$/\2/p' \
		"$RENDERED_DIR"/*.yaml | sort -u
)

if [ "${#manifest_images[@]}" -gt 0 ]; then
	for manifest_image in "${manifest_images[@]}"; do
		if [[ "$manifest_image" == *.dkr.ecr.* ]]; then
			if [[ "$manifest_image" == *@* ]]; then
				echo "DIGEST ON ECR  $manifest_image"
				fail=1
				continue
			fi

			image_name="${manifest_image##*/}"
			tagged_repository="${image_name%%:*}"
			tag="${image_name#*:}"

			if ! awk -v tagged_repository="$tagged_repository" -v tag="$tag" '
				$2 == "=" && $3 == "{" {
					repository = $1
					in_repository = 1
					next
				}
				in_repository &&
					$1 == "image_tag" &&
					$3 == ("\"" tag "\"") &&
					tagged_repository ~ ("^[a-z][a-z0-9]*-[a-z][a-z0-9-]*-" repository "$") {
						found = 1
				}
				in_repository && $1 == "}" {
					if (found) exit 0
					in_repository = 0
				}
				END { exit found ? 0 : 1 }
			' "$ECR_TF"; then
				echo "NOT IN ecr.tf  $tagged_repository:$tag"
				fail=1
			fi
		else
			if ! docker buildx imagetools inspect "$manifest_image" > /dev/null 2>&1; then
				echo "MISSING  $manifest_image (rendered manifest)"
				fail=1
			fi
		fi
	done
else
	echo "No manifest image references found" >&2
	if [ -n "$(find "$RENDERED_DIR" -type f -name '*.yaml' -print -quit)" ]; then
		echo "Rendered manifests contain no image references; refusing an incomplete check"
		fail=1
	fi
fi

exit "$fail"
