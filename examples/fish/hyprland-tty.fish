#!/usr/bin/fish

# Hyprland TTY Launcher Script
# Launches Hyprland directly from TTY login with proper environment setup
#
# Installation:
#   1. Copy to ~/.config/hypr/scripts/hyprland-tty.fish
#   2. chmod +x ~/.config/hypr/scripts/hyprland-tty.fish
#   3. Update DRM path and other settings below for your system

# Verbose startup for debugging
set TTY (tty)
echo "=== Hyprland TTY Launcher ==="
echo "TTY: $TTY"
echo "User: "(whoami)" (UID: "(id -u)")"

# ============================================================================
# IMPORTANT: Find your DRM path with: ls /run/udev/data/+drm:*
# Update the path below to match your GPU's primary display output
# ============================================================================
# Examples:
#   NVIDIA: /run/udev/data/+drm:card1-DP-1
#   AMD:    /run/udev/data/+drm:card0-DP-1
set DRM_PATH "/run/udev/data/+drm:card1-DP-1"  # <-- UPDATE THIS

while not test -e $DRM_PATH
    echo "Waiting for DRM..."
    sleep 0.2
end

# Essential environment variables
# Note: XDG_SESSION_TYPE and XDG_CURRENT_DESKTOP are set by Hyprland internally
set -gx XDG_SESSION_CLASS user

# Ensure XDG_RUNTIME_DIR exists (pam_systemd should create it, but wait to be sure)
set -l uid (id -u)
set -gx XDG_RUNTIME_DIR /run/user/$uid

# Wait for runtime dir to be created by systemd-logind (up to 5 seconds)
set -l wait_count 0
while not test -d $XDG_RUNTIME_DIR
    if test $wait_count -ge 25
        echo "ERROR: XDG_RUNTIME_DIR ($XDG_RUNTIME_DIR) not created after 5 seconds"
        echo "Check if pam_systemd is configured correctly"
        echo "Press Enter to exit..."
        read
        exit 1
    end
    echo "Waiting for runtime directory..."
    sleep 0.2
    set wait_count (math $wait_count + 1)
end
echo "Runtime directory ready: $XDG_RUNTIME_DIR"

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
