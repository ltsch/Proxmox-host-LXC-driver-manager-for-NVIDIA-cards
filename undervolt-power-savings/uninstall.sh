#!/bin/bash
set -e

SERVICE_FILE_NAME="nvidia-undervolt.service"
SYSTEMD_DIR="/etc/systemd/system"

echo "[UNINSTALL] Removing NVIDIA Undervolt service..."

# 1. Stop and Disable Service
if systemctl is-active --quiet "$SERVICE_FILE_NAME"; then
    echo "  -> Stopping service..."
    systemctl stop "$SERVICE_FILE_NAME"
fi

if systemctl is-enabled --quiet "$SERVICE_FILE_NAME"; then
    echo "  -> Disabling service..."
    systemctl disable "$SERVICE_FILE_NAME"
fi

# 2. Remove Service File
if [ -f "$SYSTEMD_DIR/$SERVICE_FILE_NAME" ]; then
    echo "  -> Removing unit file from $SYSTEMD_DIR..."
    rm -f "$SYSTEMD_DIR/$SERVICE_FILE_NAME"
    systemctl daemon-reload
    echo "[SUCCESS] Service uninstalled."
else
    echo "[INFO] Service file not found. Already uninstalled?"
fi

# 3. Note about venv
echo ""
echo "Note: The python virtual environment in 'venv/' was NOT removed."
echo "You can remove it manually if you are deleting this project."
