#!/bin/bash

# Abort on any error
set -e -u -o pipefail

# Return values
COMPOSE_FILE_MISSING=401

# Constants
COMPOSE_FILE="docker-compose.yml"


# Relative file paths
SCRIPT=$(realpath "$0")
SCRIPTS_PATH=$(dirname "$SCRIPT")
REPO_PATH=$(dirname "$SCRIPTS_PATH")
cd "$REPO_PATH"

# Useful functions
source "$SCRIPTS_PATH/helpers.sh"

# Expects Docker compose file in REPO_PATH
if test ! -f "$COMPOSE_FILE"; then
	echo_error "$COMPOSE_FILE is missing!"
	exit "$COMPOSE_FILE_MISSING"
fi

# Stop service and disable start after reboot
UNIT_PREFIX="compose"
UNIT_NAME="$UNIT_PREFIX@$(systemd-escape "$REPO_PATH")"
systemctl disable "$UNIT_NAME" --no-block --now

# Keeping the SystemD template
UNIT_PATH="/etc/systemd/system/$UNIT_PREFIX@.service"
if test -f "$UNIT_PATH"; then
	echo "Keeping the SystemD template \"$UNIT_PATH\""
fi

# Customizations to debootstrap process
DEBOOTSTRAP_CUSTOMIZATIONS="$REPO_PATH/custom/debootstrap.sh"
if test -f "$DEBOOTSTRAP_CUSTOMIZATIONS"; then
	# shellcheck disable=SC1090
	source "$DEBOOTSTRAP_CUSTOMIZATIONS"
fi
