#!/usr/bin/bash

# Hyprland TTY Launcher Script
# Launches Hyprland directly from TTY login with proper environment setup
#
# Installation:
#   1. Copy to ~/.config/hypr/scripts/hyprland-tty.sh
#   2. chmod +x ~/.config/hypr/scripts/hyprland-tty.sh
#   3. Optionally set HYPR_DRM_PATH environment variable (auto-detected if not set)

# ============================================================================
# Configuration - Override via environment variables
# ============================================================================
# HYPR_DRM_PATH - Path to wait for (auto-detected from /run/udev/data/+drm:*)
# HYPR_TIMEOUT  - Max wait time in seconds (default: 5)

: "${HYPR_TIMEOUT:=5}"

# ============================================================================
# Helper Functions
# ============================================================================

# wait_for_resource: Wait for a path to exist with timeout
#   $1 - path to wait for
#   $2 - resource name for logging
#   $3 - test type: -e (exists), -d (directory), -f (file)
#   Returns: 0 on success, 1 on timeout
wait_for_resource() {
    local path="$1"
    local name="$2"
    local test_type="${3:--e}"
    local max_iterations=$((HYPR_TIMEOUT * 5))  # 0.2s intervals
    local count=0

    while ! test "$test_type" "$path"; do
        if [ "$count" -ge "$max_iterations" ]; then
            echo "ERROR: $name ($path) not available after $HYPR_TIMEOUT seconds"
            return 1
        fi
        echo "Waiting for $name..."
        sleep 0.2
        count=$((count + 1))
    done
    echo "$name ready: $path"
    return 0
}

# detect_drm_path: Find DRM device, preferring discrete GPUs
# Priority: HYPR_DRM_PATH > nvidia > amdgpu > first available
detect_drm_path() {
    # 1. User-specified path always wins
    if [ -n "$HYPR_DRM_PATH" ]; then
        echo "$HYPR_DRM_PATH"
        return 0
    fi

    # 2. Find all cards and their drivers
    # Prefer discrete GPUs (nvidia) over integrated (amdgpu on APUs)
    for preferred_driver in nvidia amdgpu; do
        for card_dir in /sys/class/drm/card*; do
            card_name=$(basename "$card_dir")
            # Only match base cards (card0, card1) not outputs (card0-DP-1)
            if ! [[ $card_name =~ ^card[0-9]+$ ]]; then
                continue
            fi

            # Check driver type
            driver_path=$(readlink -f "$card_dir/device/driver" 2>/dev/null)
            if [[ $driver_path == */$preferred_driver ]]; then
                # Found preferred GPU, get first display output
                for drm_file in /run/udev/data/+drm:"$card_name"-*; do
                    if [ -e "$drm_file" ]; then
                        echo "$drm_file"
                        return 0
                    fi
                done
            fi
        done
    done

    # 3. Fallback: first card with any display output
    for drm_file in /run/udev/data/+drm:card*-*; do
        if [ -e "$drm_file" ]; then
            echo "$drm_file"
            return 0
        fi
    done

    return 1
}

# ============================================================================
# Main Script
# ============================================================================

echo "=== Hyprland TTY Launcher ==="
echo "TTY: $(tty)"
echo "User: $(whoami) (UID: $(id -u))"

# Wait for DRM (GPU ready)
DRM_PATH=$(detect_drm_path)
if [ -z "$DRM_PATH" ]; then
    echo "ERROR: No DRM device found. Check GPU drivers."
    echo "Hint: Run 'ls /run/udev/data/+drm:*' to see available devices"
    echo "      Set HYPR_DRM_PATH to specify manually"
    echo "Press Enter to exit..."
    read -r
    exit 1
fi

if ! wait_for_resource "$DRM_PATH" "DRM device" -e; then
    echo "Press Enter to exit..."
    read -r
    exit 1
fi

# Set XDG_RUNTIME_DIR and wait for systemd-logind to create it
export XDG_SESSION_CLASS=user
export XDG_RUNTIME_DIR=/run/user/$(id -u)

if ! wait_for_resource "$XDG_RUNTIME_DIR" "runtime directory" -d; then
    echo "Check if pam_systemd is configured correctly"
    echo "Press Enter to exit..."
    read -r
    exit 1
fi

# ============================================================================
# GPU-SPECIFIC ENVIRONMENT VARIABLES
# ============================================================================
# DISCLAIMER: You are responsible for knowing which settings are correct for
# YOUR hardware. The installer tries to detect your GPU, but no guarantees.
# Verify with: vainfo (from libva-utils package)
#
# To check your GPU driver:
#   for card in /sys/class/drm/card*; do [ -d "$card/device" ] && echo "$(basename "$card"): $(basename "$(readlink "$card/device/driver")")"; done
#
# Reference: https://wiki.archlinux.org/title/Hardware_video_acceleration
# ============================================================================

# --- NVIDIA GPU ---
# export LIBVA_DRIVER_NAME=nvidia
# export __GLX_VENDOR_LIBRARY_NAME=nvidia
# export NVD_BACKEND=direct

# --- AMD GPU (modern: Radeon HD 7000+, GCN/RDNA architecture) ---
# For older AMD (Radeon HD 2000-6000), use "r600" instead
# export LIBVA_DRIVER_NAME=radeonsi

# --- Intel GPU (modern: Broadwell 2014+, including Arc) ---
# For older Intel (GMA 4500 through Coffee Lake), use "i965" instead
# export LIBVA_DRIVER_NAME=iHD

# ============================================================================
# SAFE DEFAULTS (Usually fine for everyone on Wayland)
# ============================================================================
export QT_QPA_PLATFORM=wayland
export ELECTRON_OZONE_PLATFORM_HINT=wayland  # or "auto" if you have issues

# ============================================================================
# USER PREFERENCES (OPTIONAL - Customize to match YOUR system)
# ============================================================================
# WARNING: These are examples only! Do not enable unless you know these
# themes/settings exist on YOUR system. Leaving them commented uses system defaults.
#
# Cursor theme - check available themes: ls ~/.local/share/icons/ /usr/share/icons/
# export XCURSOR_THEME=Bibata-Modern-Classic
# export XCURSOR_SIZE=24
#
# Qt theming - only if you have kde/qt5ct/qt6ct installed
# export QT_QPA_PLATFORMTHEME=kde  # Options: kde, qt5ct, qt6ct

# Launch Hyprland via start-hyprland watchdog (0.53+)
# start-hyprland provides crash recovery and safe mode
echo "Starting Hyprland via start-hyprland..."
start-hyprland 2>&1 | tee ~/.hyprland.log
exit_code=${PIPESTATUS[0]}
echo "Hyprland exited with code: $exit_code"
echo "Press Enter to continue..."
read -r