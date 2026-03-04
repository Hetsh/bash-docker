#!/bin/bash

# Abort on any error
set -e -u -o pipefail

# Return values
COMPOSE_FILE_MISSING=301
UPLOAD_ABORT=302

# Constants
COMPOSE_FILE="docker-compose.yml"

# Ask user to upload file
function confirm_upload {
	local FILE="$1"
	while test ! -f "$FILE"; do
		if ! confirm_action "Please upload $FILE. Continue?"; then
			return "$UPLOAD_ABORT"
		fi
	done
}


# Relative file paths
SCRIPT=$(realpath "$0")
SCRIPTS_DIR=$(dirname "$SCRIPT")
REPO_DIR=$(dirname "$SCRIPTS_DIR")
cd "$REPO_DIR"

# Useful functions
source "$SCRIPTS_DIR/helpers.sh"
docker_reachable

# Expects Docker compose file in REPO_DIR
if test ! -f "$COMPOSE_FILE"; then
	echo_error "$COMPOSE_FILE is missing!"
	exit "$COMPOSE_FILE_MISSING"
fi

# Customizations to bootstrap process
BOOTSTRAP_CUSTOMIZATIONS="$REPO_DIR/custom/bootstrap.sh"
if test -f "$BOOTSTRAP_CUSTOMIZATIONS"; then
	source "$BOOTSTRAP_CUSTOMIZATIONS"
fi

#Install SystemD service template
UNIT_PREFIX="compose"
UNIT_PATH="/etc/systemd/system/$UNIT_PREFIX@.service"
if test ! -f "$UNIT_PATH"; then
	echo "[Unit]
Description=docker compose running %I
Requires=docker.service
After=docker.service
StartLimitIntervalSec=5
StartLimitBurst=5

[Service]
WorkingDirectory=%I
ExecStart=/usr/bin/docker compose up
ExecStop=/usr/bin/docker compose down
Restart=on-failure

[Install]
WantedBy=multi-user.target" > "$UNIT_PATH"
	systemctl daemon-reload
fi

#Configure start after reboot
UNIT_NAME="$UNIT_PREFIX@$(systemd-escape "$REPO_DIR")"
systemctl enable "$UNIT_NAME"

# Start the service
echo ""
echo "Bootstrap succesful!"
if confirm_action "Do you want to start the service now?"; then
	systemctl start "$UNIT_NAME" --no-block
	journalctl --follow --unit="$UNIT_NAME"
fi
