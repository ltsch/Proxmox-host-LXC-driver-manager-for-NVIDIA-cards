#!/bin/bash
set -e

# Dynamically determine the directory where this script is located
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$PROJECT_DIR/venv"
SERVICE_TEMPLATE="nvidia-undervolt.service"
SERVICE_FILE_NAME="nvidia-undervolt.service"
SYSTEMD_DIR="/etc/systemd/system"

echo "[INSTALL] Setting up NVIDIA Undervolt in $PROJECT_DIR..."

# 1. Create Virtual Environment if missing
if [ ! -d "$VENV_DIR" ]; then
    echo "[INSTALL] Creating virtual environment at $VENV_DIR..."
    python3 -m venv "$VENV_DIR"
else
    echo "[INSTALL] Virtual environment already exists."
fi

# 2. Install Dependencies
echo "[INSTALL] Installing dependencies (nvidia-ml-py)..."
"$VENV_DIR/bin/pip" install --upgrade pip
"$VENV_DIR/bin/pip" install nvidia-ml-py

# 3. Install Systemd Service with correct path
echo "[INSTALL] Configuring systemd service..."
# Replace %PATH% with actual project dir
sed "s|%PATH%|$PROJECT_DIR|g" "$PROJECT_DIR/$SERVICE_TEMPLATE" > "$SYSTEMD_DIR/$SERVICE_FILE_NAME"

# Reload systemd
systemctl daemon-reload

# Enable and Start Service
echo "[INSTALL] Enabling and starting service..."
systemctl enable "$SERVICE_FILE_NAME"
systemctl restart "$SERVICE_FILE_NAME"

# Check Status
if systemctl is-active --quiet "$SERVICE_FILE_NAME"; then
    echo "[SUCCESS] Service is running!"
    systemctl status "$SERVICE_FILE_NAME" --no-pager
else
    echo "[ERROR] Service failed to start. Check logs:"
    journalctl -u "$SERVICE_FILE_NAME" --no-pager -n 20
    exit 1
fi
