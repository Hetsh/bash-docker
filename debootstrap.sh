#!/bin/bash

# Abort on any error
set -e -u -o pipefail


# Relative file paths
SCRIPT=$(realpath "$0")
SCRIPTS_DIR=$(dirname "$SCRIPT")
REPO_DIR=$(dirname "$SCRIPTS_DIR")
cd "$REPO_DIR"

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
source "$REPO_DIR/custom/debootstrap.sh"
