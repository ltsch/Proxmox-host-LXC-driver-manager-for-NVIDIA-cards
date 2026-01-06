#!/bin/bash

# ==============================================================================
# NVIDIA Driver Upgrade Tool (v3.0)
# Purpose: Synchronize Host and LXC Containers to a specific NVIDIA Driver version.
# Features: File-based version check, orphan cleanup, forced reinstall.
# ==============================================================================

# --- Configuration ------------------------------------------------------------

# Target driver version (major.minor, e.g., "590.48" matches "590.48.01")
TARGET_VERSION="${TARGET_VERSION:-590.48}"

# Container Lists
# ---------------
# CONTAINERS_REBOOT: These containers will be rebooted after driver update.
#                    Use for containers that can tolerate brief downtime.
#                    Example: Tdarr (if you can pause transcoding)
CONTAINERS_REBOOT=(101 102)

# CONTAINERS_STAGING: These containers will NOT be rebooted automatically.
#                     Changes are staged and apply on next manual restart.
#                     Use for 24/7 services where you control the restart window.
#                     Example: Plex, Jellyfin (if always streaming)
CONTAINERS_STAGING=(103)

# !Do not list the same container in both arrays! 

# Host Packages (Debian 12 Proxmox)
HOST_PACKAGES=(
    "nvidia-driver"
    "firmware-nvidia-gsp"
    "nvidia-kernel-dkms"
)

# Container Package Mapping
# Ubuntu 24.04 - Uses generic names in CUDA repo
UBUNTU_PACKAGES=(
    "libnvidia-compute"
    "libnvidia-encode"
    "libnvidia-decode"
    "libnvidia-gl"
)

# Debian 12/13 - Specific libs for GPU transcoding
# NOTE: nvidia-smi is NOT included - it requires nvidia-alternative on trixie
# and is not needed for validation (we use file-based checks on libnvidia-ml.so)
DEBIAN_PACKAGES=(
    "libcuda1"
    "libnvidia-encode1"
    "libnvcuvid1"
    "libnvidia-ml1"
)
# ------------------------------------------------------------------------------

set -e

# --- Colors -------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# --- Helper Functions ---------------------------------------------------------
log() { echo -e "${BLUE}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        err "This script must be run as root."
    fi
}

run_cmd() {
    local cmd="$1"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${YELLOW}[DRY RUN]${NC} Would execute: $cmd"
    else
        eval "$cmd"
    fi
}


check_container_version() {
    local ct=$1
    local os_type=$2
    
    # Check for physical existence of crucial library file
    # This detects "Corrupt/Partial" states where DB says installed but files are missing/old
    # Use glob pattern to match patch versions (e.g., 590.48.01)
    local check_pattern="/usr/lib/x86_64-linux-gnu/libnvidia-ml.so.${TARGET_VERSION}*"
    
    if pct exec "$ct" -- bash -c "ls $check_pattern &>/dev/null"; then
        return 0 # File exists, truly installed
    else
        return 1 # File missing or mismatch, needs update/reinstall
    fi
}

cleanup_orphan_files() {
    local ct=$1
    # Remove orphaned library files from previous driver versions
    # These can cause "version mismatch" errors even when packages report correct version
    log "Cleaning up orphaned NVIDIA library files in container $ct..."
    run_cmd "pct exec $ct -- bash -c 'find /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu -name \"*nvidia*.5[0-8]*\" -o -name \"*cuda*.5[0-8]*\" 2>/dev/null | xargs rm -f 2>/dev/null || true'"
    run_cmd "pct exec $ct -- ldconfig"
}

# --- Main Functions -----------------------------------------------------------

configure_repo_pinning() {
    local ct=$1
    log "Configuring APT preference pinning for NVIDIA repo in $ct..."
    run_cmd "pct exec $ct -- bash -c \"cat <<EOF > /etc/apt/preferences.d/nvidia-repo-pin
Package: *
Pin: origin developer.download.nvidia.com
Pin-Priority: 1001
EOF\""
}

update_host() {
    log "--- Starting Host Upgrade ($TARGET_VERSION) ---"
    
    # Check if already at target version
    if dkms status | grep -q "nvidia/${TARGET_VERSION}.*installed"; then
        success "Host is already at target version ($TARGET_VERSION). Skipping update."
        return
    fi

    log "Stopping containers to release driver locks..."
    for ct in "${CONTAINERS_REBOOT[@]}" "${CONTAINERS_STAGING[@]}"; do
         if pct status $ct | grep -q "running"; then
             run_cmd "pct stop $ct"
         fi
    done

    log "Installing Host Packages..."
    # Unhold first
    run_cmd "apt-mark unhold ${HOST_PACKAGES[*]} libnvidia* &>/dev/null || true"
    run_cmd "apt-get update"
    
    # Install
    local install_args=""
    for pkg in "${HOST_PACKAGES[@]}"; do
        install_args="$install_args $pkg=${TARGET_VERSION}*"
    done
    
    run_cmd "DEBIAN_FRONTEND=noninteractive apt-get install -y $install_args"

    # Post-Install Config
    log "Configuring Host..."
    # Disable Xorg
    run_cmd "systemctl disable --now display-manager service 2>/dev/null || true"
    run_cmd "systemctl mask display-manager service 2>/dev/null || true"

    # Reload Driver if needed
    if ! nvidia-smi | grep -q "$TARGET_VERSION"; then
       log "Reloading NVIDIA modules..."
       run_cmd "modprobe -r nvidia_uvm nvidia_drm nvidia_modeset nvidia || true"
       run_cmd "modprobe nvidia"
    fi

    # Pin Packages
    run_cmd "apt-mark hold ${HOST_PACKAGES[*]}"
    
    success "Host Configured."
}

update_container() {
    local ct=$1
    local os_type=$2
    local reboot_required=$3
    
    log "--- Updating Container $ct ($os_type) ---"
    
    # 0. Pre-check Version
    if check_container_version "$ct" "$os_type"; then
        success "Container $ct is already at target version ($TARGET_VERSION). Skipping update."
        return
    fi
    
    # 1. Determine Packages
    local pkgs=()
    if [[ "$os_type" == "ubuntu" ]]; then
        pkgs=("${UBUNTU_PACKAGES[@]}")
    else
        pkgs=("${DEBIAN_PACKAGES[@]}")
    fi
    
    # 2. Check State
    if ! pct status $ct | grep -q "running"; then
        log "Starting container $ct..."
        run_cmd "pct start $ct"
        sleep 5
    fi

    # 3. Install
    local install_str=""
    local hold_str=""
    for pkg in "${pkgs[@]}"; do
        install_str="$install_str $pkg=${TARGET_VERSION}*"
        hold_str="$hold_str $pkg"
    done
    
    # 2.5 Configure Pinning (Debian only for now, based on observed needs)
    if [[ "$os_type" != "ubuntu" ]]; then
        configure_repo_pinning "$ct"
    fi

    log "Installing packages in $ct..."
    cleanup_orphan_files "$ct"
    run_cmd "pct exec $ct -- bash -c 'apt-mark unhold nvidia* libnvidia* &>/dev/null || true; apt-get update'"
    run_cmd "pct exec $ct -- bash -c 'DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall --allow-change-held-packages --no-install-recommends $install_str'"
    
    # 4. Pin
    run_cmd "pct exec $ct -- apt-mark hold $hold_str"

    # 4b. Disable Xorg (Safety)
    log "Ensuring Xorg is disabled in $ct..."
    run_cmd "pct exec $ct -- systemctl disable --now display-manager 2>/dev/null || true"
    run_cmd "pct exec $ct -- systemctl mask display-manager 2>/dev/null || true"
    
    # 5. Handle Restart
    if [[ "$reboot_required" == "true" ]]; then
        log "Rebooting container $ct to apply changes..."
        run_cmd "pct reboot $ct"
    else
        warn "Container $ct NOT rebooted. Driver changes will apply on next restart."
    fi
    
    success "Container $ct Updated."
}

# --- Execution ----------------------------------------------------------------

check_root

# Parse Args
DRY_RUN=false

for arg in "$@"; do
    case $arg in
        --dry-run) DRY_RUN=true ;;
    esac
done

update_host

# Process containers that WILL be rebooted
for ct in "${CONTAINERS_REBOOT[@]}"; do
    os_type=$(pct exec "$ct" -- cat /etc/os-release | grep "^ID=" | cut -d= -f2 | tr -d '"')
    update_container "$ct" "$os_type" "true"
done

# Process containers that will NOT be rebooted (staging)
for ct in "${CONTAINERS_STAGING[@]}"; do
    os_type=$(pct exec "$ct" -- cat /etc/os-release | grep "^ID=" | cut -d= -f2 | tr -d '"')
    update_container "$ct" "$os_type" "false"
done

log "=== Upgrade Process Complete ==="
