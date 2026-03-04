#!/bin/bash

# Abort on any error
set -e -u -o pipefail

# Return values
COMPOSE_FILE_MISSING=401

# Constants
COMPOSE_FILE="docker-compose.yml"


# Relative file paths
SCRIPT=$(realpath "$0")
SCRIPTS_DIR=$(dirname "$SCRIPT")
REPO_DIR=$(dirname "$SCRIPTS_DIR")
cd "$REPO_DIR"

# Useful functions
source "$SCRIPTS_DIR/helpers.sh"

# Expects Docker compose file in REPO_DIR
if test ! -f "$COMPOSE_FILE"; then
	echo_error "$COMPOSE_FILE is missing!"
	exit "$COMPOSE_FILE_MISSING"
fi

# Stop service and disable start after reboot
UNIT_PREFIX="compose"
UNIT_NAME="$UNIT_PREFIX@$(systemd-escape "$REPO_DIR")"
systemctl disable "$UNIT_NAME" --no-block --now

# Keeping the SystemD template
UNIT_PATH="/etc/systemd/system/$UNIT_PREFIX@.service"
if test -f "$UNIT_PATH"; then
	echo "Keeping the SystemD template \"$UNIT_PATH\""
fi

# Customizations to debootstrap process
DEBOOTSTRAP_CUSTOMIZATIONS="$REPO_DIR/custom/debootstrap.sh"
if test -f "$DEBOOTSTRAP_CUSTOMIZATIONS"; then
	source "$DEBOOTSTRAP_CUSTOMIZATIONS"
fi
