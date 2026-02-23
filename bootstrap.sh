#!/bin/bash

# Abort on any error
set -e -u -o pipefail

# Return values
UPLOAD_ABORT=301

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

# Check access to docker daemon
source "$SCRIPTS_DIR/helpers.sh"
docker_reachable

# Customizations to bootstrap process
source "$REPO_DIR/custom/bootstrap.sh"

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
