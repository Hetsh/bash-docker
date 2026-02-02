#!/bin/bash

# Abort on any error
set -e -u -o pipefail

# Return values
SUCCESS=0
SCRAPE_FAILED=201

# Definitions
ASSIGNMENT_REGEX="[ =:]"
EXPLICIT_UPDATE="explicit"
IMPLICIT_UPDATE="implicit"
HIDDEN_UPDATE="hidden"

# Check for available updates
_UPDATES=()
function updates_available {
	test "${#_UPDATES[@]}" -gt 0
}

# Verifies an item update is valid and tracks it
function process_update {
	local ITEM="$1"
	local CURRENT_VALUE="$2"
	local NEW_VALUE="$3"
	local PRETTY_NAME="${4-$ITEM}"
	# CURRENT_VERSION and NEW_VERSION exist for use cases, where the item is
	# referenced indirectly (like a URL that does not contain the version).
	# CURRENT_VALUE and NEW_VALUE are the values in the Dockerfile, while
	# CURRENT_VERSION and NEW_VERSION are used for user interaction.
	local CURRENT_VERSION="${5-$CURRENT_VALUE}"
	local NEW_VERSION="${6-$NEW_VALUE}"

	if test -z "$ITEM"; then
		echo_warning "Skipping empty ITEM!"
		return
	fi

	if test -z "$CURRENT_VALUE"; then
		echo_error "Failed to scrape $ITEM current value!"
		return "$SCRAPE_FAILED"
	fi

	if test -z "$NEW_VALUE"; then
		echo_error "Failed to scrape $ITEM new value!"
		return "$SCRAPE_FAILED"
	fi

	if test -z "$CURRENT_VERSION"; then
		echo_error "Failed to scrape $ITEM current version!"
		return "$SCRAPE_FAILED"
	fi

	if test -z "$NEW_VERSION"; then
		echo_error "Failed to scrape $ITEM new version!"
		return "$SCRAPE_FAILED"
	fi

	if test "$CURRENT_VALUE" == "$NEW_VALUE"; then
		return
	fi

	_UPDATES+=("$ITEM" "$CURRENT_VALUE" "$NEW_VALUE" "$CURRENT_VERSION" "$NEW_VERSION")
	_CHANGELOG+="$PRETTY_NAME $CURRENT_VERSION -> $NEW_VERSION, "

	# An explicit update refers to an item (most probably a package)
	# that is explicitly installed in the Dockerfile with a pinned version.
	# All other updates are implicit, e.g. packages already installed in
	# the base image, explicitly installed packages without a pinned version,
	# or an implicitly installed dependency.
	if sed_search "$ITEM$ASSIGNMENT_REGEX$CURRENT_VALUE" "Dockerfile"; then
		_UPDATES+=("$EXPLICIT_UPDATE")
	else
		_UPDATES+=("$IMPLICIT_UPDATE")
	fi

	echo "$PRETTY_NAME $NEW_VERSION is available!"
}

# Applies updates to Dockerfile
function save_changes {
	local i=0
	while test $i -lt ${#_UPDATES[@]}; do
		local ID=${_UPDATES[((i++))]}
		local CURRENT_VALUE=${_UPDATES[((i++))]}
		local NEW_VALUE=${_UPDATES[((i++))]}
		local CURRENT_VERSION=${_UPDATES[((i++))]}
		local NEW_VERSION=${_UPDATES[((i++))]}
		local TYPE=${_UPDATES[((i++))]}

		if test "$TYPE" == "$IMPLICIT_UPDATE"; then
			continue
		fi

		local TARGET="Dockerfile"
		assert_replace "\($ID$ASSIGNMENT_REGEX\)$CURRENT_VALUE" "\1$NEW_VALUE" "$TARGET" "Item \"$ID $CURRENT_VALUE\" not found in \"$TARGET\""
	done
}

# Push changes and next tag to git
function commit_changes {
	# Any update will be tagged with an incremented release counter
	local CURRENT_RELEASE="${GIT_VERSION##*-}"
	local NEXT_RELEASE="$((CURRENT_RELEASE + 1))"
	local NEXT_VERSION="${GIT_VERSION%-*}-$NEXT_RELEASE"

	# But if the main item was updated, use the item version as tag
	if test -n "$MAIN_ITEM"; then
		local i=0
		while test $i -lt ${#_UPDATES[@]}; do
			local ID=${_UPDATES[((i++))]}
			local CURRENT_VALUE=${_UPDATES[((i++))]}
			local NEW_VALUE=${_UPDATES[((i++))]}
			local CURRENT_VERSION=${_UPDATES[((i++))]}
			local NEW_VERSION=${_UPDATES[((i++))]}
			local TYPE=${_UPDATES[((i++))]}

			if test "$ID" != "$MAIN_ITEM"; then
				continue
			fi

			# Skip the main item update if only the release counter was incremented
			local STRIPPED_CURRENT_VERSION="${CURRENT_VERSION%%-*}"
			local STRIPPED_NEW_VERSION="${NEW_VERSION%%-*}"
			if test "$STRIPPED_CURRENT_VERSION" != "$STRIPPED_NEW_VERSION"; then
				NEXT_VERSION="$STRIPPED_NEW_VERSION-1"
			fi
		done
	fi

	git add Dockerfile
	git commit -m "${_CHANGELOG%, }"
	git tag "$NEXT_VERSION"
	git push
	git push origin "$NEXT_VERSION"
}

# Check for base image update on hub.docker.com
function update_base_image {
	local VERSION_REGEX="$1"

	local IMG && IMG=$(grep --only-matching --perl-regexp "(?<=^FROM ).+" "Dockerfile")
	local NAME && NAME="$(cut -d ":" -f 1 <<< "$IMG")"
	local CURRENT_VERSION && CURRENT_VERSION="$(cut -d ":" -f 2 <<< "$IMG")"
	local NEW_VERSION && NEW_VERSION=$(curl_request "https://registry.hub.docker.com/v2/repositories/$NAME/tags?page_size=128" | jq --raw-output ".results[].name" | grep --only-matching --perl-regexp "^$VERSION_REGEX" | sort --version-sort | tail -n 1)
	process_update "$IMG" "$CURRENT_VERSION" "$NEW_VERSION" "Base Image $IMG"
}

# Check the provided Docker image for package updates with a package manager
function update_packages {
	local IMG="$1"

	local CONTAINER_ID && CONTAINER_ID=$(docker run --quiet --rm --detach --entrypoint sleep "$IMG:$GIT_VERSION" 60)
	if docker exec --user root "$CONTAINER_ID" test -e "/sbin/apk"; then
		local UPGRADE_COMMAND="apk upgrade"
		local UPGRADEABLE_PACKAGES_FUNCTION="upgradeable_packages_apk"
		local PROCESS_LIST_FUNCTION="process_list_apk"
	elif docker exec --user root "$CONTAINER_ID" test -e "/bin/apt-get"; then
		local UPGRADE_COMMAND="apt full-upgrade"
		local UPGRADEABLE_PACKAGES_FUNCTION="upgradeable_packages_apt"
		local PROCESS_LIST_FUNCTION="process_list_apt"
	else
		echo_error "No supported package manager found in image \"$IMG\"!"
		return "$UNSUPPORTED_PACKAGE_MANAGER"
	fi

	local DF="Dockerfile"
	local REBUILD_TRIGGER="ARG LAST_UPGRADE"
	# Without the upgrade command, implicitly installed packages would not be updated
	assert_search "$UPGRADE_COMMAND" "$DF" "No \"$UPGRADE_COMMAND\" found in \"$DF\"!"
	# The REBUILD_TRIGGER is used to make an arbitrary change to the Dockerfile, triggering a rebuild of the image
	assert_search "^$REBUILD_TRIGGER=.\+" "$DF" "No \"$REBUILD_TRIGGER\" found in \"$DF\"!"

	local PKG_LIST && PKG_LIST=$("$UPGRADEABLE_PACKAGES_FUNCTION" "$CONTAINER_ID")
	# Abort when no packages are available for upgrade, because mapfile can't
	# handle an empty PKG_LIST properly (or I don't know how to use it). It
	# would produce an array with one empty element, which breaks everything...
	if test -z "$PKG_LIST"; then
		return
	fi
	mapfile -t "PKG_LIST" <<< "$PKG_LIST"
	"$PROCESS_LIST_FUNCTION" "${PKG_LIST[@]}"

	# Append current date and time to the UPGRADE_KEYWORD without putting it in the
	# changelog to keep track of implicit updates.
	if updates_available; then
		_UPDATES+=("$REBUILD_TRIGGER" ".\+" "\"$(date --iso-8601=seconds)\"" "_" "_" "$HIDDEN_UPDATE")
	fi
}

# Get a list of upgradeable packages in an Alpine container
function upgradeable_packages_apk {
	local CONTAINER_ID="$1"

	docker exec --user root "$CONTAINER_ID" apk update > /dev/null
	docker exec --user root "$CONTAINER_ID" apk list --upgradeable
}

# Process the list of upgradeable packages from the Alpine Package Keeper
function process_list_apk {
	local PKG_LIST=("$@")

	for LINE in "${PKG_LIST[@]}"; do
		local FIRST_FIELD && FIRST_FIELD=$(awk '{print $1}' <<< "$LINE")
		local PKG && PKG=$(grep --only-matching --perl-regexp "^.+(?=-\d)" <<< "$FIRST_FIELD")
		local NEW_VERSION && NEW_VERSION=$(grep --only-matching --perl-regexp "(?<=-)\d+.+" <<< "$FIRST_FIELD")
		local LAST_FIELD && LAST_FIELD=$(awk '{print $NF}' <<< "$LINE")
		local CURRENT_VERSION && CURRENT_VERSION=$(grep --only-matching --perl-regexp "(?<=-)\d+[^\]]+" <<< "$LAST_FIELD")
		process_update "$PKG" "$CURRENT_VERSION" "$NEW_VERSION"
	done
}

# Get a list of upgradeable packages in a Debian container
function upgradeable_packages_apt {
	local CONTAINER_ID="$1"

	docker exec --user root "$CONTAINER_ID" apt-get update > /dev/null
	docker exec --user root "$CONTAINER_ID" apt-get -o "APT::Get::Show-User-Simulation-Note=false" --simulate full-upgrade | { grep ^Inst || true; }
}

# Process the list of upgradeable packages from the Advanced Package Tool
function process_list_apt {
	local PKG_LIST=("$@")

	for LINE in "${PKG_LIST[@]}"; do
		local PKG && PKG=$(cut --only-delimited --delimiter " " --field 2 <<< "$LINE")
		local CURRENT_VERSION && CURRENT_VERSION=$(cut --only-delimited --delimiter " " --field 3 <<< "$LINE" | tr -d "[]")
		local NEW_VERSION && NEW_VERSION=$(cut --only-delimited --delimiter " " --field 4 <<< "$LINE" | tr -d "(")
		process_update "$PKG" "$CURRENT_VERSION" "$NEW_VERSION"
	done
}
function update_github {
	local REPO="$1"
	local VERSION_ID="$2"
	local VERSION_REGEX="$3"
	local PRETTY_NAME="${4-$VERSION_ID}"
	local CLEANUP_REGEX="${5-"^v"}"

	local CURRENT_VERSION && CURRENT_VERSION=$(grep --only-matching --perl-regexp "(?<=$VERSION_ID$ASSIGNMENT_REGEX)$VERSION_REGEX" "Dockerfile")
	local NEW_VERSION && NEW_VERSION=$(curl_request "https://api.github.com/repos/$REPO/releases/latest" | jq -r ".tag_name" | sed "s|$CLEANUP_REGEX||")
	process_update "$VERSION_ID" "$CURRENT_VERSION" "$NEW_VERSION" "$PRETTY_NAME"
}

# Check for new tag in a git repository
function update_git {
	local URL="$1"
	local VERSION_ID="$2"
	local VERSION_REGEX="$3"
	local PRETTY_NAME="${4-$VERSION_ID}"

	local CURRENT_VERSION && CURRENT_VERSION=$(grep --only-matching --perl-regexp "(?<=$VERSION_ID$ASSIGNMENT_REGEX)$VERSION_REGEX" "Dockerfile")
	local NEW_VERSION && NEW_VERSION=$(git ls-remote --tags "$URL" | cut --only-delimited --field 2 | grep --only-matching --perl-regexp "(?<=refs/tags/)$VERSION_REGEX" | sort --version-sort | tail -n 1)
	process_update "$VERSION_ID" "$CURRENT_VERSION" "$NEW_VERSION" "$PRETTY_NAME"
}

# Check for update on webpage
function update_web {
	local VAR="$1"
	local URL="$2"
	local VAL_REGEX="$3"
	local PRETTY_NAME="${4-$VAR}"

	local CURRENT_VAR && CURRENT_VAR=$(grep --only-matching --perl-regexp "(?<=$VAR$ASSIGNMENT_REGEX)$VAL_REGEX" "Dockerfile")
	local NEW_VAR && NEW_VAR=$(curl_request "$URL" | grep --only-matching --perl-regexp "$VAL_REGEX" | sort --version-sort | tail -n 1)
	process_update "$VAR" "$CURRENT_VAR" "$NEW_VAR" "$PRETTY_NAME"
}

# Check for update on http file server
function update_fileserver {
	local VAR="$1"
	local URL="$2"
	local VAL_REGEX="$3"
	local PRETTY_NAME="${4-$VAR}"

	local CURRENT_VAL && CURRENT_VAL=$(grep --only-matching --perl-regexp "(?<=$VAR$ASSIGNMENT_REGEX)$VAL_REGEX" Dockerfile)
	local NEW_VAL && NEW_VAL=$(curl_request "$URL" | grep --only-matching --perl-regexp "$VAL_REGEX(?=/)" | sort --version-sort | tail -n 1)
	process_update "$VAR" "$CURRENT_VAL" "$NEW_VAL" "$PRETTY_NAME"
}

# Check for update on pypi
function update_pypi {
	local PKG="$1"
	local VERSION_REGEX="$2"

	local CURRENT_VERSION && CURRENT_VERSION=$(grep --only-matching --perl-regexp "(?<=$PKG=$ASSIGNMENT_REGEX)$VERSION_REGEX" "Dockerfile")
	local NEW_VERSION && NEW_VERSION=$(curl_request "https://pypi.org/pypi/$PKG/json" | jq -r ".info.version")
	process_update "$PKG" "$CURRENT_VERSION" "$NEW_VERSION"
}


# Simpler git usage, relative file paths
SCRIPT=$(realpath "$0")
SCRIPTS_DIR=$(dirname "$SCRIPT")
REPO_DIR=$(dirname "$SCRIPTS_DIR")
cd "$REPO_DIR"

# Check access to docker daemon
source "$SCRIPTS_DIR/helpers.sh"
docker_reachable

# Customizations to update workflow
source "$REPO_DIR/custom/update.sh"
var_is_set "MAIN_ITEM"
var_is_set "GIT_VERSION"

if ! updates_available; then
	echo "No updates available."
	exit "$SUCCESS"
fi

# Perform modifications
if test "${1-}" = "--noconfirm" || confirm_action "Save changes?"; then
	save_changes

	if test "${1-}" = "--noconfirm" || confirm_action "Commit changes?"; then
		commit_changes
	fi
fi
