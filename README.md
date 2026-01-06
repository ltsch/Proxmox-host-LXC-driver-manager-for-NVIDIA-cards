# NVIDIA Driver Sync for Proxmox LXC

A bash utility to synchronize NVIDIA driver versions between a Proxmox VE host and its LXC containers, enabling GPU passthrough for applications like Plex, Jellyfin, and Tdarr.

## The Problem

When sharing an NVIDIA GPU with unprivileged LXC containers on Proxmox, the **userspace libraries inside the container must exactly match the kernel driver version on the host**. A mismatch causes errors like:

```
Failed to initialize NVML: Driver/library version mismatch
NVML library version: 590.44
```

Manually keeping multiple containers in sync with the host is tedious and error-prone. This script automates the process.

> [!NOTE]
> Full disclosure: This project contains some AI-written code because I am not a very good developer. I have reviewed the code myself, but transparency is key.

## Features

- **Idempotent**: Safely re-run anytime - skips containers already at target version
- **File-Based Validation**: Checks actual `.so` files exist (not just package DB)
- **Orphan Cleanup**: Removes leftover library files from previous versions
- **Forced Reinstall**: Fixes corrupted/partial installs automatically
- **Dry-Run Mode**: Preview changes before applying
- **OS-Aware**: Handles Ubuntu and Debian package naming differences
- **APT Pinning**: Locks packages to prevent version drift

## Requirements

- Proxmox VE 8.x with NVIDIA drivers installed via DKMS
- LXC containers with GPU passthrough configured
- NVIDIA CUDA repository configured in containers
- Root access on the Proxmox host

## Quick Start

1. **Configure** - Edit the script to set your container IDs and target version:
   ```bash
   TARGET_VERSION="590.48"
   
   # Containers that will be rebooted after update
   CONTAINERS_REBOOT=(101 103)
   
   # Containers that will NOT be rebooted (staged for manual restart)
   CONTAINERS_STAGING=(102)
   ```

2. **Dry Run** - Preview what will happen:
   ```bash
   ./upgrade_drivers.sh --dry-run
   ```

3. **Execute** - Apply the changes:
   ```bash
   ./upgrade_drivers.sh
   ```

## Configuration

### Target Version
```bash
TARGET_VERSION="${TARGET_VERSION:-590.48}"
```
Set via environment variable or edit directly. Use the major.minor version (e.g., `590.48` matches `590.48.01`).

### Container Lists
Configure which containers to update and how to handle reboots:

```bash
# CONTAINERS_REBOOT: Rebooted immediately after update.
# Use for containers that can tolerate brief downtime.
CONTAINERS_REBOOT=(101 103)

# CONTAINERS_STAGING: NOT rebooted automatically.
# Changes apply on next manual restart.
# Use for 24/7 services where you control the restart window.
CONTAINERS_STAGING=(102)
```

### Package Lists
The script auto-detects OS and uses the correct packages:

| Distro | Packages |
|--------|----------|
| Ubuntu 24.04 | `libnvidia-compute`, `libnvidia-encode`, `libnvidia-decode`, `libnvidia-gl` |
| Debian 12/13 | `libcuda1`, `libnvcuvid1`, `libnvidia-encode1`, `libnvidia-ml1` |

## Troubleshooting

### "Driver/library version mismatch" in Container
**Cause**: Orphaned `.so` files from a previous driver version.

**Fix**: The script handles this automatically with `cleanup_orphan_files()`. For manual cleanup:
```bash
pct exec <CT_ID> -- bash -c "find /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu -name '*nvidia*.<OLD_VERSION>*' | xargs rm -f && ldconfig"
```

### "Driver/library version mismatch" on Host
**Cause**: Running containers holding old driver in memory.

**Fix**:
1. Stop all GPU containers: `pct stop <CT_ID>`
2. Reload kernel modules:
   ```bash
   modprobe -r nvidia_uvm nvidia_drm nvidia_modeset nvidia
   modprobe nvidia
   ```

### Script reports "up to date" but nvidia-smi fails
**Cause**: Package DB is inconsistent with actual files (corrupt state).

**Fix**: Temporarily change `TARGET_VERSION` to force reinstall, or manually run:
```bash
pct exec <CT_ID> -- apt-get install -y --reinstall <packages>
```

### APT errors about missing repository
Some third-party repos may not support newer Debian versions (e.g., trixie). Remove the offending source:
```bash
pct exec <CT_ID> -- rm /etc/apt/sources.list.d/<broken-repo>.list
pct exec <CT_ID> -- apt-get update
```

## How It Works

1. **Host Check**: Verifies DKMS module matches target version
2. **Container Check**: Verifies `libnvidia-ml.so.<VERSION>` exists in each container
3. **Cleanup**: Removes orphaned library files from older versions
4. **Install**: Runs `apt-get install --reinstall` with version pinning
5. **Lock**: Holds packages with `apt-mark hold` to prevent drift
6. **Reboot**: Optionally reboots container to apply changes

## License

MIT License

## Contributing

Issues and PRs welcome. Please test and provide logs when submitting changes.
