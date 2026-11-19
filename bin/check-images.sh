#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

ECR_TF="aws/envs/eu-west-1/ecr.tf"
RENDERED_DIR="build/validate/rendered"
fail=0

if ! command -v docker > /dev/null 2>&1; then
	echo "Required command not found: docker" >&2
	exit 1
fi

if [ ! -d "$RENDERED_DIR" ]; then
	echo "Rendered manifests not found; run bin/validate.sh first" >&2
	exit 1
fi

while IFS= read -r dockerfile; do
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
	sed -nE 's/^[[:space:]]*image:[[:space:]]*"?([^"[:space:]]+)"?[[:space:]]*$/\1/p' \
		"$RENDERED_DIR"/*.yaml | sort -u
)

for manifest_image in "${manifest_images[@]}"; do
	if [[ "$manifest_image" == *.dkr.ecr.* ]]; then
		image_name="${manifest_image##*/}"
		repository="${image_name%%:*}"
		tag="${image_name#*:}"
		if [[ "$tag" == *"@"* ]]; then
			tag="${tag%%@*}"
		fi

		if ! awk -v repository="$repository" -v tag="$tag" '
			$1 == repository && $2 == "=" && $3 == "{" { in_repository = 1 }
			in_repository && $1 == "image_tag" && $3 == ("\"" tag "\"") { found = 1 }
			in_repository && $1 == "}" { if (found) exit 0; in_repository = 0 }
			END { exit found ? 0 : 1 }
		' "$ECR_TF"; then
			echo "NOT IN ecr.tf  $repository:$tag"
			fail=1
		fi
	else
		if ! docker buildx imagetools inspect "$manifest_image" > /dev/null 2>&1; then
			echo "MISSING  $manifest_image (rendered manifest)"
			fail=1
		fi
	fi
done

exit "$fail"
