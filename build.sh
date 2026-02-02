#!/bin/bash

# Abort on any error
set -e -u -o pipefail

# Return values
SUCCESS=0
UNKNOWN_TASK=1

# Build image and export it's identifier to variable IMG_ID
function build_image {
	docker build .
	IMG_ID=$(docker build -q .)
}

# Find tags for this image and export them to variable TAGS
function find_tags {
	TAGS=("latest")

	# Account for git to be in detached head state
	local GIT_BRANCH && GIT_BRANCH="$(git branch --show-current)"
	if test -n "$GIT_BRANCH"; then
		GIT_BRANCH=$(basename "$GIT_BRANCH")
		TAGS+=("$GIT_BRANCH")
	fi

	# Account for multiple tags on the current commit
	for GIT_TAG in $(git tag --points-at); do
		GIT_TAG=$(basename "$GIT_TAG")
		TAGS+=("$GIT_TAG")
	done
}

# Run a command with all TAGS for this image
function for_all_tags {
	for TAG in "${TAGS[@]}"; do
		"$@" "$IMG_NAME:$(basename "$TAG")"
	done
}

# Apply TAGS to this image
function tag_image {
	for_all_tags docker tag "$IMG_ID"
	for_all_tags echo Tagged image:
}

# Use variable IMG_ID to start a container
function test_image {
	docker run --rm "$IMG_ID"
}


# Simpler git usage, relative file paths
SCRIPT=$(realpath "$0")
SCRIPTS_DIR=$(dirname "$SCRIPT")
REPO_DIR=$(dirname "$SCRIPTS_DIR")
cd "$REPO_DIR"

# Check access to docker daemon
source "$SCRIPTS_DIR/helpers.sh"
docker_reachable

# Customizations to build process
source "$REPO_DIR/custom/build.sh"
var_is_set "IMG_NAME"

TASK="${1-}"
case "$TASK" in
	# Build image and assign tags
	"--tag")
		build_image
		find_tags
		tag_image
	;;
	# Build image and run test
	"--test")
		build_image
		test_image
	;;
	# Build and push tagged image
	"--upload")
		find_tags
		TAGS_EXIST=true
		EXISTING_TAGS=$(curl_request "https://registry.hub.docker.com/v2/repositories/$IMG_NAME/tags")
		for TAG in "${TAGS[@]}"; do
			if ! grep --quiet --only-matching "\"name\":\"$TAG\"" <<< "$EXISTING_TAGS"; then
				TAGS_EXIST=false
				break
			fi
		done
		if test "$TAGS_EXIST" == "true"; then
			echo "Image already exists, no need to upload!"
			exit "$SUCCESS"
		fi

		build_image
		tag_image
		for_all_tags docker push
	;;
	# Build image and output image identifier
	"")
		build_image
		echo "Build successful!"
		echo "The image has not been tagged!"
		echo "Use the image ID instead: $IMG_ID"
	;;
	# Catch and notify about unknown task
	*)
		echo_error "Unknown task \"$TASK\"!"
		exit "$UNKNOWN_TASK"
	;;
esac
