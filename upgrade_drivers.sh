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
CONTAINERS_REBOOT=(100)

# CONTAINERS_STAGING: These containers will NOT be rebooted automatically.
#                     Changes are staged and apply on next manual restart.
#                     Use for 24/7 services where you control the restart window.
#                     Example: Plex, Jellyfin (if always streaming)
CONTAINERS_STAGING=()

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

validate_container() {
    local ct=$1
    # Check if container exists
    if ! pct status "$ct" &>/dev/null; then
        warn "Container $ct does not exist. Skipping."
        return 1
    fi
    return 0
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

configure_nvidia_repo() {
    local ct=$1
    local os_type=$2
    
    # Check if NVIDIA repo is already configured
    if pct exec "$ct" -- bash -c "apt-cache policy | grep -q 'developer.download.nvidia.com'"; then
        log "NVIDIA repository already configured in container $ct"
        return 0
    fi
    
    log "Adding NVIDIA CUDA repository to container $ct ($os_type)..."
    
    if [[ "$os_type" == "ubuntu" ]]; then
        # Ubuntu 24.04
        run_cmd "pct exec $ct -- bash -c 'wget -q https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb -O /tmp/cuda-keyring.deb'"
        run_cmd "pct exec $ct -- dpkg -i /tmp/cuda-keyring.deb"
        run_cmd "pct exec $ct -- rm -f /tmp/cuda-keyring.deb"
    else
        # Debian 12/13
        local debian_version
        debian_version=$(pct exec "$ct" -- bash -c "grep VERSION_ID /etc/os-release | cut -d= -f2 | tr -d '\"'")
        
        if [[ "$debian_version" == "12" ]]; then
            run_cmd "pct exec $ct -- bash -c 'wget -q https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/cuda-keyring_1.1-1_all.deb -O /tmp/cuda-keyring.deb'"
        elif [[ "$debian_version" == "13" ]]; then
            run_cmd "pct exec $ct -- bash -c 'wget -q https://developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64/cuda-keyring_1.1-1_all.deb -O /tmp/cuda-keyring.deb'"
        else
            warn "Unsupported Debian version: $debian_version. Skipping repo configuration."
            return 1
        fi
        
        run_cmd "pct exec $ct -- dpkg -i /tmp/cuda-keyring.deb"
        run_cmd "pct exec $ct -- rm -f /tmp/cuda-keyring.deb"
    fi
    
    success "NVIDIA repository configured in container $ct"
}

configure_host_nvidia_repo() {
    # Check if NVIDIA repo is already configured
    if apt-cache policy | grep -q 'developer.download.nvidia.com'; then
        log "NVIDIA repository already configured on host"
        return 0
    fi
    
    log "Adding NVIDIA CUDA repository to host..."
    
    # Host is assumed to be Debian (Proxmox)
    local debian_version
    if [ -f /etc/os-release ]; then
        debian_version=$(grep VERSION_ID /etc/os-release | cut -d= -f2 | tr -d '"')
    else
        warn "Could not detect OS version on host. Skipping repo configuration."
        return 1
    fi
    
    if [[ "$debian_version" == "12" ]]; then
        run_cmd "wget -q https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/cuda-keyring_1.1-1_all.deb -O /tmp/cuda-keyring.deb"
    elif [[ "$debian_version" == "13" ]]; then
        run_cmd "wget -q https://developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64/cuda-keyring_1.1-1_all.deb -O /tmp/cuda-keyring.deb"
    else
        warn "Unsupported Debian version on host: $debian_version. Skipping repo configuration."
        return 1
    fi
    
    run_cmd "dpkg -i /tmp/cuda-keyring.deb"
    run_cmd "rm -f /tmp/cuda-keyring.deb"
    
    success "NVIDIA repository configured on host"
}

update_host() {
    log "--- Starting Host Upgrade ($TARGET_VERSION) ---"

    # Ensure Repo is present
    configure_host_nvidia_repo

    # Ensure Nouveau is blacklisted (Policy)
    blacklist_nouveau
    
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
    
    # Install Headers (unpinned)
    run_cmd "DEBIAN_FRONTEND=noninteractive apt-get install -y proxmox-default-headers"

    # Install
    local install_args=""
    for pkg in "${HOST_PACKAGES[@]}"; do
        install_args="$install_args $pkg=${TARGET_VERSION}*"
    done
    
    # We must force reinstall to trigger DKMS build if it failed previously (e.g. missing headers)
    run_cmd "DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall $install_args"

    # Post-Install Config
    log "Configuring Host..."
    # Disable Xorg
    run_cmd "systemctl disable --now display-manager service 2>/dev/null || true"
    run_cmd "systemctl mask display-manager service 2>/dev/null || true"

    # Blacklist Nouveau
    blacklist_nouveau

    # Reload Driver if needed
    if ! grep -q "$TARGET_VERSION" /proc/driver/nvidia/version 2>/dev/null; then
       log "Reloading NVIDIA modules..."
       
       # Unload Nouveau if present (prevents NVIDIA load)
       if lsmod | grep -q nouveau; then
           warn "Nouveau driver is loaded. Attempting to unload..."
           run_cmd "modprobe -r nouveau || true"
       fi
       
       run_cmd "modprobe -r nvidia_uvm nvidia_drm nvidia_modeset nvidia || true"
       run_cmd "modprobe nvidia"
    fi

    # Pin Packages
    run_cmd "apt-mark hold ${HOST_PACKAGES[*]}"
    
    success "Host Configured."
}

blacklist_nouveau() {
    local ct=$1
    local config_content="blacklist nouveau\noptions nouveau modeset=0"
    
    if [[ -z "$ct" ]]; then
        # Host
        log "Blacklisting nouveau on host..."
        run_cmd "echo -e '$config_content' > /etc/modprobe.d/blacklist-nouveau.conf"
        # We might need to update initramfs, but that's slow. 
        # The user just wants it blacklisted so it doesn't load.
        # Ensure it's not loaded now is handled in reload block.
    else
        # Container
        log "Blacklisting nouveau in container $ct..."
        run_cmd "pct exec $ct -- bash -c \"echo -e '$config_content' > /etc/modprobe.d/blacklist-nouveau.conf\""
    fi
}

update_container() {
    local ct=$1
    local os_type=$2
    local reboot_required=$3
    
    log "--- Updating Container $ct ($os_type) ---"
    
    # 1. Determine Packages
    local pkgs=()
    if [[ "$os_type" == "ubuntu" ]]; then
        pkgs=("${UBUNTU_PACKAGES[@]}")
    else
        pkgs=("${DEBIAN_PACKAGES[@]}")
    fi
    
    # 2. Check State & Ensure Running
    if ! pct status $ct | grep -q "running"; then
        log "Starting container $ct..."
        run_cmd "pct start $ct"
        # In dry run, we won't actually be running, so subsequent execs would fail if not guarded or if we don't return.
        # However, for check_container_version, we need to know if we should check.
        if [[ "$DRY_RUN" == "true" ]]; then
             warn "Dry Run: Container $ct is stopped. Start command skipped. Skipping version check/install simulation for this container to avoid errors."
             return
        fi
        sleep 5
    fi

    # Blacklist Nouveau (Host-mandated policy)
    blacklist_nouveau "$ct"

    # 0. Pre-check Version
    if check_container_version "$ct" "$os_type"; then
        success "Container $ct is already at target version ($TARGET_VERSION). Skipping update."
        return
    fi

    # 3. Install
    local install_str=""
    local hold_str=""
    for pkg in "${pkgs[@]}"; do
        install_str="$install_str $pkg=${TARGET_VERSION}*"
        hold_str="$hold_str $pkg"
    done
    
    # 2.5 Configure NVIDIA Repository
    configure_nvidia_repo "$ct" "$os_type"
    
    # 2.6 Configure Pinning (Debian only for now, based on observed needs)
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
        log "Restarting container $ct to apply changes..."
        run_cmd "pct stop $ct && sleep 2 && pct start $ct"
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
    validate_container "$ct" || continue
    os_type=$(pct exec "$ct" -- cat /etc/os-release | grep "^ID=" | cut -d= -f2 | tr -d '"')
    update_container "$ct" "$os_type" "true"
done

# Process containers that will NOT be rebooted (staging)
for ct in "${CONTAINERS_STAGING[@]}"; do
    validate_container "$ct" || continue
    os_type=$(pct exec "$ct" -- cat /etc/os-release | grep "^ID=" | cut -d= -f2 | tr -d '"')
    update_container "$ct" "$os_type" "false"
done

log "=== Upgrade Process Complete ==="
