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
SCRIPTS_PATH=$(dirname "$SCRIPT")
REPO_PATH=$(dirname "$SCRIPTS_PATH")
cd "$REPO_PATH"

# Useful functions
source "$SCRIPTS_PATH/helpers.sh"
docker_reachable

# Expects Docker compose file in REPO_PATH
if test ! -f "$COMPOSE_FILE"; then
	echo_error "$COMPOSE_FILE is missing!"
	exit "$COMPOSE_FILE_MISSING"
fi

# Customizations to bootstrap process
BOOTSTRAP_CUSTOMIZATIONS="$REPO_PATH/custom/bootstrap.sh"
if test -f "$BOOTSTRAP_CUSTOMIZATIONS"; then
	# shellcheck disable=SC1090
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
StartLimitIntervalSec=60
StartLimitBurst=30

[Service]
WorkingDirectory=%I
ExecStart=/usr/bin/docker compose up --abort-on-container-exit
ExecStop=/usr/bin/docker compose down
Restart=on-failure
RestartSec=1

[Install]
WantedBy=multi-user.target" > "$UNIT_PATH"
	systemctl daemon-reload
fi

#Configure start after reboot
UNIT_NAME="$UNIT_PREFIX@$(systemd-escape "$REPO_PATH")"
systemctl enable "$UNIT_NAME"

# Start the service
echo ""
echo "Bootstrap succesful!"
if confirm_action "Do you want to start the service now?"; then
	systemctl start "$UNIT_NAME" --no-block
	journalctl --all --follow --unit="$UNIT_NAME"
fi
