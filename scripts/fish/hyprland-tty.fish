#!/usr/bin/fish

# Hyprland TTY Launcher Script
# Launches Hyprland directly from TTY login with proper environment setup
#
# Installation:
#   1. Copy to ~/.config/hypr/scripts/hyprland-tty.fish
#   2. chmod +x ~/.config/hypr/scripts/hyprland-tty.fish
#   3. Optionally set HYPR_DRM_PATH environment variable (auto-detected if not set)

# ============================================================================
# Configuration - Override via environment variables
# ============================================================================
# HYPR_DRM_PATH - Path to wait for (auto-detected from /run/udev/data/+drm:*)
# HYPR_TIMEOUT  - Max wait time in seconds (default: 5)

set -q HYPR_TIMEOUT; or set HYPR_TIMEOUT 5

# ============================================================================
# Helper Functions
# ============================================================================

# wait_for_resource: Wait for a path to exist with timeout
#   $argv[1] - path to wait for
#   $argv[2] - resource name for logging
#   $argv[3] - test type: -e (exists), -d (directory), -f (file)
#   Returns: 0 on success, 1 on timeout
function wait_for_resource
    set -l path $argv[1]
    set -l name $argv[2]
    set -l test_type $argv[3]; or set test_type -e
    set -l max_iterations (math "$HYPR_TIMEOUT * 5")  # 0.2s intervals
    set -l count 0

    while not test $test_type $path
        if test $count -ge $max_iterations
            echo "ERROR: $name ($path) not available after $HYPR_TIMEOUT seconds"
            return 1
        end
        echo "Waiting for $name..."
        sleep 0.2
        set count (math $count + 1)
    end
    echo "$name ready: $path"
    return 0
end

# detect_drm_path: Find first available DRM device
function detect_drm_path
    # Prefer user-specified path
    if set -q HYPR_DRM_PATH
        echo $HYPR_DRM_PATH
        return 0
    end

    # Auto-detect: find first card with a display output
    for drm_file in /run/udev/data/+drm:card*-*
        if test -e $drm_file
            echo $drm_file
            return 0
        end
    end

    # Fallback: any DRM card
    for drm_file in /run/udev/data/+drm:card*
        if test -e $drm_file
            echo $drm_file
            return 0
        end
    end

    return 1
end

# ============================================================================
# Main Script
# ============================================================================

echo "=== Hyprland TTY Launcher ==="
echo "TTY: "(tty)
echo "User: "(whoami)" (UID: "(id -u)")"

# Wait for DRM (GPU ready)
set DRM_PATH (detect_drm_path)
if test -z "$DRM_PATH"
    echo "ERROR: No DRM device found. Check GPU drivers."
    echo "Hint: Run 'ls /run/udev/data/+drm:*' to see available devices"
    echo "      Set HYPR_DRM_PATH to specify manually"
    echo "Press Enter to exit..."
    read
    exit 1
end

if not wait_for_resource $DRM_PATH "DRM device" -e
    echo "Press Enter to exit..."
    read
    exit 1
end

# Set XDG_RUNTIME_DIR and wait for systemd-logind to create it
set -gx XDG_SESSION_CLASS user
set -gx XDG_RUNTIME_DIR /run/user/(id -u)

if not wait_for_resource $XDG_RUNTIME_DIR "runtime directory" -d
    echo "Check if pam_systemd is configured correctly"
    echo "Press Enter to exit..."
    read
    exit 1
end

# ============================================================================
# GPU-specific environment variables
# Uncomment/modify based on your GPU
# ============================================================================

# NVIDIA GPU
set -gx LIBVA_DRIVER_NAME nvidia
set -gx __GLX_VENDOR_LIBRARY_NAME nvidia
set -gx NVD_BACKEND direct

# AMD GPU (uncomment if using AMD, comment out NVIDIA vars above)
# set -gx LIBVA_DRIVER_NAME radeonsi

# ============================================================================
# Optional: Cursor theme (update to your preferred theme)
# ============================================================================
set -gx XCURSOR_THEME Bibata-Modern-Classic
set -gx XCURSOR_SIZE 24

# ============================================================================
# Qt/Wayland settings
# ============================================================================
set -gx QT_QPA_PLATFORM wayland
set -gx QT_QPA_PLATFORMTHEME kde  # or qt5ct, qt6ct, etc.

# ============================================================================
# Electron apps (Discord, VSCode, Slack, etc.)
# SDDM often sets this implicitly - needed for native Wayland
# ============================================================================
set -gx ELECTRON_OZONE_PLATFORM_HINT wayland  # or "auto"

# Launch Hyprland - capture output for debugging
echo "Starting Hyprland..."
Hyprland 2>&1 | tee ~/.hyprland.log
set -l exit_code $pipestatus[1]
echo "Hyprland exited with code: $exit_code"
echo "Press Enter to continue..."
read
