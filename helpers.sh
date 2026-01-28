#!/bin/bash

# Return values
DOCKER_NOT_REACHABLE=101
REQUEST_FAILED=102
EXTRACTION_FAILED=103
PATTERN_NOT_FOUND=104
PATTERN_MALFORMED=105
VARIABLE_NOT_SET=106
ACTION_DENIED=107

# Output yellow message on stdout
function echo_warning {
	MESSAGE="$1"
	echo -e "\e[33m$MESSAGE\e[0m"
}

# Output red message on stderr
function echo_error {
	MESSAGE="$1"
	>&2 echo -e "\e[31m$MESSAGE\e[0m"
}

# Check if docker daemon is reachable
function docker_reachable {
	if ! docker version &> /dev/null; then
		echo_error "Docker daemon is not running or you have insufficient permissions!"
		return $DOCKER_NOT_REACHABLE
	fi
}

# Use SED with a regex pattern to check for file content
function sed_search {
	local PATTERN="$1"
	local TARGET="$2"

	# Can't use !{q123} to return 123 when the pattern is not found, because sed
	# will abort after the first line that does not match the pattern. Instead
	# using q123 to return 123 when the pattern was matched and then inverting the
	# result.
	local EXIT_CODE && EXIT_CODE=$(sed --quiet "\|$PATTERN|q123" "$TARGET"; echo "$?")
	if test "$EXIT_CODE" == "123"; then
		return
	elif test "$EXIT_CODE" == "0"; then
		return "$PATTERN_NOT_FOUND"
	else
		exit "$PATTERN_MALFORMED"
	fi
}

# Assert that a file contains the specified regex pattern
function assert_search {
	local PATTERN="$1"
	local TARGET="$2"
	local ERROR_MESSAGE="$3"

	if ! sed_search "$PATTERN" "$TARGET"; then
		echo_error "$ERROR_MESSAGE"
		return "$PATTERN_NOT_FOUND"
	fi
}

# Verify that sed actually found the pattern to replace
function assert_replace {
	local PATTERN="$1"
	local REPLACEMENT="$2"
	local TARGET="$3"
	local ERROR_MESSAGE="$4"

	assert_search "$PATTERN" "$TARGET" "$ERROR_MESSAGE"
	sed -i "s|$PATTERN|$REPLACEMENT|" "$TARGET"
}

# Get value from file by key
extract_val() {
	local KEY="$1"
	local FILE="$2"
	local SEPARATOR="${4:-"[ =:]"}"
	local REGEX="${3:-".*"}"

	local VALUE && VALUE="$(grep --perl-regexp --only-matching "(?<=$KEY$SEPARATOR)$REGEX" "$FILE" | sed -e 's/^"//' -e 's/"$//')"
	if test -z "$VALUE"; then
		echo_error "Failed to extract value of \"$KEY\" from \"$FILE\"!"
		return $EXTRACTION_FAILED
	fi

	local -n EXPORT="$KEY"
	export EXPORT="$VALUE"
}

# A cURL HTTP request with error handling
function curl_request {
	local RESPONSE_FILE && RESPONSE_FILE=$(mktemp)
	local HTTP_CODE && HTTP_CODE=$(curl \
		--netrc-optional \
		--silent \
		--show-error \
		--write-out "%{http_code}" \
		--output "$RESPONSE_FILE" \
		"$@")
	cat "$RESPONSE_FILE"
	rm "$RESPONSE_FILE"

	if test "$HTTP_CODE" -ge 300; then
		echo_error "Request failed: $HTTP_CODE"
		return "$REQUEST_FAILED"
	fi
}

# Assert that a variable is set
function var_is_set {
	local VAR_NAME="$1"
	if test -z "${!VAR_NAME+x}"; then
		echo_error "\"$VAR_NAME\" is not set!"
		return $VARIABLE_NOT_SET
	fi
}

# Ask user if action should be performed
confirm_action() {
	local MESSAGE="$1"
	read -p "$MESSAGE [y/n]" -n 1 -r && echo
	if test "$REPLY" != "y"; then
		return $ACTION_DENIED
	fi
}
