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

- **Idempotent**: Safely re-run anytime — skips reinstall when DKMS already matches `TARGET_VERSION`, but **still reapplies holds** on the host and in containers
- **File-Based Validation**: Checks actual `.so` files exist (not just package DB)
- **Orphan Cleanup**: Removes leftover library files from previous versions
- **Forced Reinstall**: Fixes corrupted/partial installs automatically
- **Dry-Run Mode**: Prints `apt-mark` / `pct exec` commands it would run (see note below)
- **OS-Aware**: Handles Ubuntu and Debian package naming differences
- **Version lock (host)**: `apt-mark hold` on **`HOST_PACKAGES` plus every installed proprietary NVIDIA stack package** reported by `dpkg` (so `apt upgrade` does not drift the driver userland)
- **Containers (Debian)**: Optional `preferences.d` entry favoring packages from `developer.download.nvidia.com`; **managed packages** are held with `apt-mark hold` after install

## Requirements

- Proxmox VE 8.x with NVIDIA drivers installed via DKMS
- LXC containers with GPU passthrough configured
- NVIDIA CUDA repository configured in containers
- Root access on the Proxmox host
- NVIDIA RTX 3090/4090 (for undervolting features)

## GPU Optimization (Undervolt)

This repository includes a standalone tool for **headless GPU undervolting** and power management (Clock Lock + Power Limit).

👉 **[See undervolt-power-savings/README.md](undervolt-power-savings/README.md)** for details.

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
| Debian 12/13 | `libcuda1`, `libnvidia-encode1`, `libnvcuvid1`, `libnvidia-ml1` |

### Dry-run (`--dry-run`)

Commands passed through `run_cmd` (e.g. `apt-mark hold`, `pct exec …`) are **only printed**, not executed. **Host-side helpers** such as `ensure_device_nodes()` and `ensure_nvidia_smi()` still touch the system when run as root — use dry-run from a throwaway shell if you need a pure preview.

### `apt list --upgradable` vs holds

Newer driver versions may still **appear** in `apt list --upgradable` while packages are **on hold**. What matters is that **`apt upgrade`** does not install them. Verify with `apt-mark showhold` and `apt -s upgrade` if unsure.

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

### Host locks up or becomes unusable during `apt upgrade` / kernel install

**Cause**: Installing a **new Proxmox kernel** runs `/etc/kernel/postinst.d/dkms`, which can **rebuild NVIDIA via DKMS** with high parallelism (`make -j$(nproc)`). On a busy node (many VMs/CTs, **heavy swap**), `cc1` can sit in **uninterruptible disk sleep** for a long time and the machine may **appear frozen**.

**Mitigation**:

- Run major upgrades in a **maintenance window**; reduce load (**stop** large guests) and **free RAM** before kernel + NVIDIA builds.
- After an **unclean shutdown**, boot may run **fsck** on `pve-root` (orphan inode cleanup is normal). Then check: `dpkg --audit` and `DEBIAN_FRONTEND=noninteractive dpkg --configure -a` if nothing else holds the dpkg lock.

### `pct` or UI slow while `dpkg` / DKMS is running

The package database and subsystem load can make **`pct`** and the UI sluggish. That is environmental, not necessarily a dead node.

## How It Works

1. **Host**: Ensures NVIDIA CUDA repo exists; if DKMS already has `nvidia/<TARGET_VERSION>` **installed**, skips reinstall but **applies `apt-mark hold`** on the full detected NVIDIA stack (plus `HOST_PACKAGES`) and runs device-node / `nvidia-smi` helpers
2. **Host (upgrade path)**: Stops listed containers, `apt-get install --reinstall` with `pkg=<TARGET_VERSION>*`, then **holds** the stack again
3. **Container Check**: Verifies `libnvidia-ml.so.<VERSION>*` exists
4. **Cleanup**: Removes orphaned library files from older versions
5. **Container install**: Configures CUDA repo, Debian: `preferences.d` origin pin, `apt-get install --reinstall` with version wildcard, **`apt-mark hold`** on the managed package set
6. **Container (already at version)**: Skips install but **reapplies holds**
7. **Reboot**: Optionally stops/starts container to apply changes

## License

MIT License

## Contributing

Issues and PRs welcome. Please test and provide logs when submitting changes.
