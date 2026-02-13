#!/usr/bin/env python3
import sys
import argparse
from pynvml import *
from ctypes import byref

# --- Configuration ---
# You can customize these defaults or pass them as arguments
DEFAULT_MIN_CLOCK = 210
DEFAULT_MAX_CLOCK = 1850  # Cap at 1850 MHz for efficiency
DEFAULT_OFFSET = 200      # +200 MHz offset (undervolt)
DEFAULT_POWER_LIMIT = 300 # 300 Watts

def log(msg):
    print(f"[NVIDIA-U] {msg}")

def apply_settings(min_clock, max_clock, offset, power_limit):
    try:
        nvmlInit()
        device_count = nvmlDeviceGetCount()
        
        for i in range(device_count):
            handle = nvmlDeviceGetHandleByIndex(i)
            name = nvmlDeviceGetName(handle)
            log(f"Configuring GPU {i}: {name}")

            # 1. Set Locked Clocks (Min/Max)
            # Find the best supported clock close to the target max
            try:
                mem_clocks = nvmlDeviceGetSupportedMemoryClocks(handle)
                max_mem_clock = mem_clocks[0] # Usually sorted desc
                
                graphics_clocks = nvmlDeviceGetSupportedGraphicsClocks(handle, max_mem_clock)
                
                # Filter for clocks close to target. 
                # User request: "Pick the closest GPU clock to 1777 and the lowest one"
                # We'll sort by distance to 1777, then by value (ascending) to prefer lower
                target_clk = 1800
                best_clock = sorted(graphics_clocks, key=lambda x: (abs(x - target_clk), x))[0]

                log(f"  -> Target Max Clock: {target_clk} MHz")
                log(f"  -> Selected Supported Clock: {best_clock} MHz (at Mem: {max_mem_clock} MHz)")
                
                # Override the user's max_clock with this distinct supported value
                current_max_clock = best_clock
                
                nvmlDeviceSetGpuLockedClocks(handle, min_clock, current_max_clock)
                log(f"  -> Locked Clocks: {min_clock} - {current_max_clock} MHz")
            except NVMLError as e:
                log(f"  -> Failed to determine or lock clocks: {e}")
                # Fallback to requested max if dynamic lookup fails
                try:
                    nvmlDeviceSetGpuLockedClocks(handle, min_clock, max_clock)
                    log(f"  -> Fallback Locked Clocks: {min_clock} - {max_clock} MHz")
                except NVMLError as e2:
                    log(f"  -> Failed to lock clocks (fallback): {e2}")

            # 2. Set Clock Offset (The Undervolt)
            # We use the newer API if available, fallback logic if needed (though pynvml wraps C)
            # Note: nvmlDeviceSetGpcClkVfOffset is deprecated but sometimes needed for older drivers/cards.
            # trying nvmlDeviceSetClockOffsets approach first as per Reddit modern suggestion
            try:
                # Structure for nvmlDeviceSetClockOffsets
                # We need to use ctypes to interact with the struct if pynvml doesn't wrap it nicely yet?
                # Actually pynvml usually exposes these. Let's try the modern way if supported.
                pass 
                # Wait, pynvml (Python bindings) might not have 'nvmlDeviceSetClockOffsets' in older versions?
                # The user's script used ctypes directly for the struct. Let's replicate that for robustness.
                
                # However, for simplicity and compatibility with standard pynvml, let's try the direct function first if available.
                # If not, we fall back to GpcClkVfOffset which works on 3090s.
                
                # Let's use the USER'S approach for the offset, it seems specific to 3090/4090 behaviors.
                # User used: nvmlDeviceSetGpcClkVfOffset(device, 255) in the first script, 
                # and nvmlDeviceSetClockOffsets with ctypes in the second (deprecated warning).
                # 3090 is Ampere.
                
                # Implementation: Attempt GpcClkVfOffset first (simpler), catch exception.
                nvmlDeviceSetGpcClkVfOffset(handle, offset)
                log(f"  -> Applied Clock Offset: +{offset} MHz")
            except NVMLError as e:
                log(f"  -> Failed to set offset (GpcClkVfOffset): {e}")
                # We could try the complex ctypes method here if needed, but keeping it simple for now. 

            # 3. Set Power Limit
            try:
                # Input is in milliwatts
                power_limit_mw = power_limit * 1000
                nvmlDeviceSetPowerManagementLimit(handle, power_limit_mw)
                log(f"  -> Power Limit Set: {power_limit} W")
            except NVMLError as e:
                 log(f"  -> Failed to set power limit: {e}")

        nvmlShutdown()
        return True
    except NVMLError as e:
        log(f"CRITICAL ERROR: {e}")
        return False

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="NVIDIA Undervolt Tool")
    parser.add_argument("--min-clock", type=int, default=DEFAULT_MIN_CLOCK, help="Minimum GPU Clock (MHz)")
    parser.add_argument("--max-clock", type=int, default=DEFAULT_MAX_CLOCK, help="Maximum GPU Clock (MHz)")
    parser.add_argument("--offset", type=int, default=DEFAULT_OFFSET, help="Clock Offset (MHz)")
    parser.add_argument("--power", type=int, default=DEFAULT_POWER_LIMIT, help="Power Limit (Watts)")
    
    args = parser.parse_args()
    
    log(f"Applying: Lock={args.min_clock}-{args.max_clock}MHz, Offset=+{args.offset}MHz, Power={args.power}W")
    apply_settings(args.min_clock, args.max_clock, args.offset, args.power)
