# NVIDIA Undervolt & Power Savings

This project provides a robust, headless-friendly way to optimize NVIDIA GPUs (specifically RTX 3090/4090) on Linux servers (Proxmox/Debian).

It uses the `nvidia-ml-py` library to interact directly with the GPU driver, bypassing the need for an X server (unlike `nvidia-settings`).

## Features
-   **Dynamic Clock Locking**: Automatically finds the supported GPU clock closest to your target (default: ~1777 MHz).
-   **Clock Offset**: Applies a positive clock offset (default: +200 MHz) to achieve higher performance at lower voltages (undervolting).
-   **Power Limiting**: Caps the maximum power draw (default: 300W).
-   **Path Agnostic**: Can be installed from any directory.
-   **Systemd Integration**: Runs automatically at boot.

## Installation

1.  Run the installation script:
    ```bash
    ./install.sh
    ```
    This will:
    -   Create a local Python virtual environment (`venv/`).
    -   Install dependencies (`nvidia-ml-py`).
    -   Configure and enable the `nvidia-undervolt.service` systemd unit.

2.  Verify it's running:
    ```bash
    systemctl status nvidia-undervolt
    ```

## Uninstallation

To remove the service and disable the optimization:

```bash
./uninstall.sh
```

## Configuration

You can modify defaults by editing `undervolt.py`:

-   `DEFAULT_MAX_CLOCK`: Target maximum clock frequency (MHz).
-   `DEFAULT_OFFSET`: Clock offset (MHz).
-   `DEFAULT_POWER_LIMIT`: Power limit (Watts).
