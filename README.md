<h1 align="center">hypr-login</h1>

Boot directly into Hyprland from TTY autologin, using hyprlock as your login screen and no display manager required.

This guide walks you through replacing SDDM (or any display manager) with a simpler boot chain:

```
systemd → getty (autologin) → Fish shell → Hyprland → hyprlock
```

> **⚠️ Heads up**: This setup modifies your boot process. Make sure you understand each step and have a recovery plan (like a live USB) before proceeding. If something goes wrong, you'll need to fix it from another TTY or recovery environment.

> **🔧 Customization Required**: The launcher script contains GPU and environment settings that **you must customize for your system**. The script has sensible defaults commented out - you'll need to uncomment the lines matching YOUR GPU (NVIDIA, AMD, or Intel) and optionally configure theme preferences. **Do not blindly copy the script without reading the comments!**

> **🧪 Experimental**: This project is under active development. The manual installation steps below are the most reliable method. An interactive installer (`setup.sh`) exists on the `feature/uwsm-extras` branch but is still being refined.

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Before You Begin: Customization Checklist](#before-you-begin-customization-checklist)
- [Architecture](#architecture)
  - [Repository Structure](#repository-structure)
  - [Installation Paths](#installation-paths-where-files-end-up)
- [Implementation](#implementation)
  - [Phase 1: Create Launcher Script](#phase-1-create-launcher-script)
  - [Phase 2: Create Fish Login Handler](#phase-2-create-fish-login-handler)
  - [Phase 3: Add hyprlock exec-once](#phase-3-add-hyprlock-exec-once)
  - [Phase 4: Staged Testing](#phase-4-staged-testing)
  - [Phase 5: Live Cutover](#phase-5-live-cutover)
- [Recovery Procedures](#recovery-procedures)
- [Pitfalls & Solutions](#pitfalls--solutions)
- [Shell Compatibility](#shell-compatibility)
- [Hardware Notes](#hardware-notes)
  - [NVIDIA GPU](#nvidia-gpu)
  - [AMD GPU](#amd-gpu)
  - [Hybrid GPU (NVIDIA + AMD iGPU)](#hybrid-gpu-nvidia--amd-igpu)
- [Credential Manager Setup](#credential-manager-setup)
- [Verification Commands](#verification-commands)
- [Complete File Contents](#complete-file-contents)
- [Sources](#sources)

---

## Overview

### What This Setup Achieves

Replace the SDDM display manager with a leaner boot path:

| Before (SDDM) | After (TTY Autologin) |
|---------------|----------------------|
| Boot → SDDM greeter → Login → Hyprland | Boot → TTY autologin → Hyprland → hyprlock |
| SDDM theming overhead | No display manager overhead |
| ~5+ second SDDM delay | ~3 seconds to desktop |
| Qt5/6 greeter rendering | Plain text login (auto) |

### Boot Flow Comparison

```
SDDM Way:
  systemd → sddm.service → SDDM greeter (Qt/Wayland)
      → User types password → Hyprland starts → Desktop

TTY Autologin Way:
  systemd → getty@tty1 (autologin) → Fish login shell
      → hyprland-autostart.fish → hyprland-tty.fish
          → Wait for DRM/GPU ready
          → Set environment variables
          → Launch Hyprland
              → exec-once = hyprlock (immediate lock)
              → User unlocks → Desktop
```

### Security Considerations

> **Acknowledged Vulnerability**: There's a brief window between Hyprland launch and hyprlock activation where the desktop is technically accessible. This guide assumes:
>
> - Your machine is not in a public/shared environment
> - Physical access to your machine already implies trust
> - Anyone sophisticated enough to exploit this timing window has bigger attack vectors available
>
> If this concerns you, this setup may not be appropriate for your threat model.

---

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| Hyprland | Tested with 0.52.2+ |
| hyprlock | Tested with 0.9.2+ |
| Fish shell | Primary shell (bash/zsh possible with modifications) |
| systemd | For getty and autologin |
| NVIDIA, AMD, or Intel GPU | GPU-specific DRM paths and env vars differ |

---

## Before You Begin: Customization Checklist

Before copying any files, you'll need to customize the launcher script for your system. The script is organized into clearly labeled sections:

### Required Customization

| Section | What to Do |
|---------|------------|
| **GPU-Specific Variables** | Uncomment the lines matching YOUR GPU (NVIDIA, AMD, or Intel). Only ONE GPU section should be uncommented. |
| **Username in autologin.conf** | Replace `YOUR_USERNAME` with your actual username. |

### Optional Customization

| Section | What to Do |
|---------|------------|
| **User Preferences** | Cursor theme, Qt theme, etc. are commented out by default. Only uncomment if you know the theme exists on your system. |
| **Timeout Values** | `HYPR_TIMEOUT` defaults to 5 seconds. Increase if you have slow storage or GPU initialization. |

### How to Check Your GPU Type

```fish
# Run this command to see your GPU driver:
for card in /sys/class/drm/card*; test -d $card/device && echo (basename $card): (readlink $card/device/driver | xargs basename); end

# Example output:
# card0: amdgpu    <- AMD GPU
# card1: nvidia    <- NVIDIA GPU
```

---

## Architecture

### Repository Structure

This repo provides ready-to-use files that you copy to your system:

| Repo Path | Copy To | Purpose |
|-----------|---------|---------|
| `scripts/fish/hyprland-tty.fish` | `~/.config/hypr/scripts/` | Main launcher script |
| `scripts/fish/hyprland-autostart.fish` | `~/.config/fish/conf.d/` | Fish login hook |
| `configs/systemd/autologin.conf` | `/etc/systemd/system/getty@tty1.service.d/` | Autologin override |
| `configs/hyprland/execs.conf` | Your Hyprland execs config | hyprlock startup |
| `contrib/systemd/hyprland.service` | *(Optional, untested)* | Alternative systemd approach |

### Installation Paths (Where Files End Up)

| File | Purpose |
|------|---------|
| `~/.config/hypr/scripts/hyprland-tty.fish` | Main launcher with env setup, DRM wait, runtime dir wait |
| `~/.config/fish/conf.d/hyprland-autostart.fish` | Fish login hook that triggers the launcher |
| `~/.config/hypr/custom.d/regular/execs.conf` (or wherever your custom execs are stored) | Contains `exec-once = hyprlock` at the top |
| `/etc/systemd/system/getty@tty1.service.d/autologin.conf` | Systemd override for autologin |

### Boot Sequence Diagram

**Quick timeline** (~3 seconds total):
```
Boot → getty autologin → Fish → DRM wait → Hyprland → hyprlock → Desktop
       (0s)              (1s)   (1-2s)     (2-3s)     (3s)       (unlock)
```

**Detailed flow**:
```
┌─────────────────────────────────────────────────────────────────┐
│  systemd                                                        │
│    └── getty@tty1.service (autologin override)                  │
│          └── /usr/bin/agetty --autologin <username>             │
│                └── Fish login shell                             │
│                      └── conf.d/hyprland-autostart.fish         │
│                            └── scripts/hyprland-tty.fish        │
│                                  ├── Wait for DRM (GPU ready)   │
│                                  ├── Wait for XDG_RUNTIME_DIR   │
│                                  ├── Set environment variables  │
│                                  └── exec Hyprland              │
│                                        └── exec-once = hyprlock │
│                                              └── User unlocks   │
│                                                    └── Desktop  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Implementation

### Phase 1: Create Launcher Script

Copy `scripts/fish/hyprland-tty.fish` to `~/.config/hypr/scripts/hyprland-tty.fish`:

```fish
#!/usr/bin/fish

# Hyprland TTY Launcher Script
# Launches Hyprland directly from TTY login with proper environment setup
#
# Configuration (via environment variables):
#   HYPR_DRM_PATH - Path to wait for (auto-detected if not set)
#   HYPR_TIMEOUT  - Max wait time in seconds (default: 5)

set -q HYPR_TIMEOUT; or set HYPR_TIMEOUT 5

# ──────────────────────────────────────────────────────────────────
# Helper Functions
# ──────────────────────────────────────────────────────────────────

# wait_for_resource: Wait for a path to exist with timeout
function wait_for_resource
    set -l path $argv[1]
    set -l name $argv[2]
    set -l test_type $argv[3]; or set test_type -e
    set -l max_iterations (math "$HYPR_TIMEOUT * 5")
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

# detect_drm_path: Find DRM device, preferring discrete GPUs
# Priority: HYPR_DRM_PATH > nvidia > amdgpu > first available
function detect_drm_path
    if set -q HYPR_DRM_PATH
        echo $HYPR_DRM_PATH
        return 0
    end

    # Prefer discrete GPUs (nvidia) over integrated (amdgpu on APUs)
    for preferred_driver in nvidia amdgpu
        for card_dir in /sys/class/drm/card*
            set -l card_name (basename $card_dir)
            # Only match base cards (card0, card1) not outputs (card0-DP-1)
            if not string match -qr '^card[0-9]+$' $card_name
                continue
            end
            set -l driver_path (readlink -f $card_dir/device/driver 2>/dev/null)
            if string match -q "*/$preferred_driver" $driver_path
                for drm_file in /run/udev/data/+drm:$card_name-*
                    if test -e $drm_file
                        echo $drm_file
                        return 0
                    end
                end
            end
        end
    end

    # Fallback: first card with any display output
    for drm_file in /run/udev/data/+drm:card*-*
        if test -e $drm_file
            echo $drm_file
            return 0
        end
    end
    return 1
end

# ──────────────────────────────────────────────────────────────────
# Main Script
# ──────────────────────────────────────────────────────────────────

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

if not wait_for_resource "$DRM_PATH" "DRM device" -e
    echo "Press Enter to exit..."
    read
    exit 1
end

# Wait for XDG_RUNTIME_DIR
set -gx XDG_SESSION_CLASS user
set -gx XDG_RUNTIME_DIR /run/user/(id -u)

if not wait_for_resource "$XDG_RUNTIME_DIR" "runtime directory" -d
    echo "Check if pam_systemd is configured correctly"
    echo "Press Enter to exit..."
    read
    exit 1
end

# ──────────────────────────────────────────────────────────────────
# GPU-SPECIFIC ENVIRONMENT VARIABLES
# ──────────────────────────────────────────────────────────────────
# IMPORTANT: Uncomment ONLY the section matching YOUR GPU!
# Using the wrong GPU settings will cause issues.
#
# To check your GPU:
#   for card in /sys/class/drm/card*; test -d $card/device && echo (basename $card): (readlink $card/device/driver | xargs basename); end
# ──────────────────────────────────────────────────────────────────

# --- NVIDIA GPU ---
# Uncomment these three lines if you have an NVIDIA GPU:
# set -gx LIBVA_DRIVER_NAME nvidia
# set -gx __GLX_VENDOR_LIBRARY_NAME nvidia
# set -gx NVD_BACKEND direct

# --- AMD GPU ---
# Uncomment this line if you have an AMD GPU:
# set -gx LIBVA_DRIVER_NAME radeonsi

# --- Intel GPU ---
# Uncomment this line if you have an Intel GPU:
# set -gx LIBVA_DRIVER_NAME iHD

# ──────────────────────────────────────────────────────────────────
# SAFE DEFAULTS (Usually fine for everyone on Wayland)
# ──────────────────────────────────────────────────────────────────
set -gx QT_QPA_PLATFORM wayland
set -gx ELECTRON_OZONE_PLATFORM_HINT wayland  # or "auto" if you have issues

# ──────────────────────────────────────────────────────────────────
# USER PREFERENCES (OPTIONAL - Customize to match YOUR system)
# ──────────────────────────────────────────────────────────────────
# WARNING: These are examples only! Do not enable unless you know these
# themes/settings exist on YOUR system. Leaving them commented uses system defaults.
#
# Cursor theme - check available themes: ls ~/.local/share/icons/ /usr/share/icons/
# set -gx XCURSOR_THEME Bibata-Modern-Classic
# set -gx XCURSOR_SIZE 24
#
# Qt theming - only if you have kde/qt5ct/qt6ct installed
# set -gx QT_QPA_PLATFORMTHEME kde  # Options: kde, qt5ct, qt6ct

# ──────────────────────────────────────────────────────────────────
# Launch Hyprland
# ──────────────────────────────────────────────────────────────────
echo "Starting Hyprland..."
Hyprland 2>&1 | tee ~/.hyprland.log
set -l exit_code $pipestatus[1]
echo "Hyprland exited with code: $exit_code"
echo "Press Enter to continue..."
read
```

Make it executable:

```bash
chmod +x ~/.config/hypr/scripts/hyprland-tty.fish
```

### Phase 2: Create Fish Login Handler

Create `~/.config/fish/conf.d/hyprland-autostart.fish`:

```fish
# Hyprland TTY Autostart
# Auto-launches Hyprland on tty1/tty2 login, handles crashes gracefully

# Only on login shell, on tty1 or tty2
if status is-login
    set TTY (tty)
    if string match -q '/dev/tty1' $TTY; or string match -q '/dev/tty2' $TTY
        echo "=== TTY Autostart: Launching Hyprland ==="

        # Attempt to start Hyprland
        ~/.config/hypr/scripts/hyprland-tty.fish

        # If we get here, Hyprland exited/crashed
        set EXIT_CODE $status

        if test $EXIT_CODE -eq 0
            # Clean exit (user logged out) - restart immediately
            echo "Hyprland exited cleanly, restarting..."
            exit 0
        else
            # Crash or error - give time to read
            echo ""
            echo "========================================="
            echo "Hyprland CRASHED with code: $EXIT_CODE"
            echo "========================================="
            echo ""
            echo "Check ~/.hyprland.log for details"
            echo ""
            echo "Restarting in 10 seconds..."
            echo "(Press Ctrl+C to stay in TTY)"
            sleep 10
            exit 0
        end
    end
end
```

### Phase 3: Add hyprlock exec-once

Add to the **TOP** of your Hyprland execs config (e.g., `~/.config/hypr/custom.d/regular/execs.conf`):

```ini
# Pseudo-login screen - lock immediately on boot (no delay!)
exec-once = hyprlock
```

> **Important**: This must be the first `exec-once` with no `sleep` delay. hyprlock should lock the screen before any other applications become visible.

**Optional**: If `path = screenshot` in your hyprlock config captures a blank/minimal screen on boot, add a commented static wallpaper alternative:

```ini
# In your hyprlock.conf background section:
background {
    monitor =
    path = screenshot
    # path = /home/user/Pictures/wallpaper.jpg  # Alternative: static wallpaper for boot
    blur_passes = 4
    blur_size = 7
}
```

### Phase 4: Staged Testing

Before disabling SDDM, test on tty2 while SDDM still works as fallback.

> **⚠️ Expect a "crash" if Hyprland is already running**: You can't run two Hyprland instances simultaneously (GPU contention). If SDDM launched Hyprland on tty1, the tty2 test will fail - that's expected! You're testing that the *script runs correctly*, not running a second session. Watch for the "Starting Hyprland..." message to confirm the script worked.

```bash
# Start getty on tty2 for testing
sudo systemctl start getty@tty2

# Switch to tty2
# Press Ctrl+Alt+F2

# Login with your password
# Fish should auto-run the launcher
# You should see "Starting Hyprland..." (script working!)
# Then it will "crash" due to GPU contention (expected)
```

**Test VT switching** before proceeding:
- Native Ctrl+Alt+F1-F6 should work
- If not working, see [VT Switching Issues](#vt-switching-issues)

**If something goes wrong**, enable Hyprland logging for troubleshooting:

```ini
# In your hyprland.conf debug section:
debug {
    disable_logs = false  # Default is true - enable this to collect logs
}
```

Logs will appear in `~/.hyprland.log` (our launcher script also tees output there).

### Phase 5: Live Cutover

```bash
# Step 1: Create autologin systemd override
sudo mkdir -p /etc/systemd/system/getty@tty1.service.d

# Replace 'YOUR_USERNAME' with your username
echo '[Service]
ExecStart=
ExecStart=-/usr/bin/agetty -o "-p -f -- \\u" --noclear --autologin YOUR_USERNAME %I $TERM' | sudo tee /etc/systemd/system/getty@tty1.service.d/autologin.conf

# Step 2: Disable SDDM (keep installed for easy rollback)
sudo systemctl disable sddm

# Step 3: Reload systemd and reboot
sudo systemctl daemon-reload
sudo reboot
```

---

## Recovery Procedures

### From Another TTY

If Hyprland fails but you can still switch TTYs:

```bash
# Press Ctrl+Alt+F3 to switch to tty3
# Login with your credentials

# Re-enable SDDM and start it immediately
sudo systemctl enable sddm
sudo systemctl start sddm

# If start doesn't work, reboot:
# sudo reboot
```

The `start` command should launch SDDM immediately without needing a reboot. If that doesn't work for some reason, reboot as a fallback.

### From Recovery/Live USB

If you can't access any TTY:

> **Note**: I have not personally tested this method, but believe it to be correct. YMMV.

```bash
# Boot from live USB
mount /dev/sdXn /mnt  # Your root partition

# Option 1: Remove autologin override
rm /mnt/etc/systemd/system/getty@tty1.service.d/autologin.conf

# Option 2: Re-enable SDDM
arch-chroot /mnt systemctl enable sddm

# Reboot
umount /mnt
reboot
```

### Quick Rollback

```bash
sudo systemctl disable getty@tty1
sudo systemctl enable sddm
sudo systemctl start sddm  # Starts SDDM immediately (reboot if this doesn't work)
```

---

## Pitfalls & Solutions

### Critical Pitfalls

| Pitfall | Symptom | Root Cause | Solution |
|---------|---------|------------|----------|
| **XDG_RUNTIME_DIR race** | "not set (is Hyprland running?)" | Script runs before systemd-logind creates `/run/user/$UID` | Add wait loop in launcher script (up to 5 seconds) |
| **D-Bus missing** | Desktop services fail, apps can't communicate | Missing `dbus-update-activation-environment` in exec-once | Add `exec-once = dbus-update-activation-environment --all` (usually already present) |
| **Exit code 0 confusion** | "Hyprland exited with code 0" but nothing started | Redundant TTY check in launcher with early `exit 0` | Remove redundant check, let autostart handle TTY validation |
| **GPU contention** | "Hyprland crashed" on tty2 during testing | Can't run two Wayland compositors on same GPU | Expected - only one Hyprland instance per GPU |
| **DRM not ready** | Hyprland fails to start, GPU-related errors | Script starts before GPU is initialized | Add DRM wait loop checking `/run/udev/data/+drm:*` |
| **Electron apps broken** | Discord, VSCode, Slack crash or use XWayland | SDDM set `ELECTRON_OZONE_PLATFORM_HINT` for you | Add `set -gx ELECTRON_OZONE_PLATFORM_HINT wayland` to launcher (or auto, your choice) |

### VT Switching Issues

**First, ensure F-keys send proper keycodes** by adding to your Hyprland `input` section:

```ini
input {
    kb_options = fkeys:basic_13-24
}
```

Without this, F-keys may send weird/media key inputs instead of standard function key codes.

| Symptom | Cause | Solution |
|---------|-------|----------|
| Ctrl+Alt+F* does nothing | Keyboard F-keys in media mode | Toggle Fn-lock (Keychron: Fn+X+L for ~3 seconds) |
| Ctrl+Alt+F* does nothing | Keys sending weird codes | Add `kb_options = fkeys:basic_13-24` to input config (see above) |
| Switching works outbound but crashes inbound | Hyprland bug #4839 with custom monitor resolutions | May improve after SDDM bypass; use workaround binds below |
| Native switching unreliable | Various compositor/driver issues | Use workaround binds below |

**Workaround keybinds** (if native Ctrl+Alt+F* doesn't work):

```bash
# First, allow passwordless chvt:
echo "$USER ALL=(ALL) NOPASSWD: /usr/bin/chvt" | sudo tee /etc/sudoers.d/chvt
```

```ini
# Then add to your Hyprland binds.conf:
bind = CTRL ALT, F1, exec, sudo chvt 1
bind = CTRL ALT, F2, exec, sudo chvt 2
bind = CTRL ALT, F3, exec, sudo chvt 3
bind = CTRL ALT, F4, exec, sudo chvt 4
bind = CTRL ALT, F5, exec, sudo chvt 5
bind = CTRL ALT, F6, exec, sudo chvt 6
```

---

## Shell Compatibility

**This guide uses Fish shell.** Other shells require modifications.

> **Contributions welcome!** See `contrib/bash/` and `contrib/zsh/` for placeholder directories awaiting community-contributed ports.

| Fish | Bash Equivalent | Zsh Equivalent |
|------|-----------------|----------------|
| `set -gx VAR value` | `export VAR=value` | `export VAR=value` |
| `status is-login` | `shopt -q login_shell` | `[[ -o login ]]` |
| `string match -q` | `[[ $var == pattern ]]` | `[[ $var == pattern ]]` |
| `set -l varname` | `local varname` | `local varname` |
| `(command)` | `$(command)` | `$(command)` |
| `conf.d/` auto-sourcing | Source from `.bash_profile` | Source from `.zprofile` |
| `math $x + 1` | `$((x + 1))` | `$((x + 1))` |
| `$pipestatus[1]` | `${PIPESTATUS[0]}` | `${pipestatus[1]}` |

### Bash Adaptation Notes

- Place autostart logic in `~/.bash_profile` (login shell)
- Check for login shell: `shopt -q login_shell && echo "login"`
- Fish `conf.d/` auto-sourcing doesn't exist in bash

### Zsh Adaptation Notes

- Place autostart logic in `~/.zprofile` (login shell)
- Check for login shell: `[[ -o login ]]`
- Use `${pipestatus[1]}` for pipeline exit codes (1-indexed like Fish)

---

## Alternative: Systemd Service Approach

> **⚠️ Untested**: This systemd service approach was contributed by the community but has not been personally tested. Use at your own risk.

Instead of fish scripts, you can use a systemd service to launch Hyprland. This approach:
- Lets systemd handle dependencies (no manual DRM/XDG_RUNTIME_DIR waits)
- Uses `dbus-run-session` for D-Bus session management
- Is more "systemd native" but less flexible

Create `/etc/systemd/system/hyprland.service`:

```ini
[Unit]
Description=Hyprland
After=graphical.target
Wants=graphical.target

[Service]
ExecStart=/usr/bin/env bash -c '[[ "$XDG_VTNR" -eq 1 ]] && exec dbus-run-session /usr/share/wayland-sessions/hyprland.desktop || systemctl isolate multi-user.target'
Restart=no
StandardInput=tty
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
KillMode=process

[Install]
WantedBy=graphical.target
```

Enable with:
```bash
sudo systemctl enable hyprland.service
```

**Note**: You still need `exec-once = hyprlock` in your Hyprland config for the lock screen.

For more systemd-based approaches, see:
- [Hyprland Wiki: Systemd Start](https://wiki.hypr.land/Useful-Utilities/Systemd-start/)
- [UWSM](https://github.com/Vladimir-csp/uwsm) - Universal Wayland Session Manager

---

## Hardware Notes

> **Note**: The launcher script has all GPU options commented out by default. Uncomment the section matching your GPU - don't just copy-paste from here.

### NVIDIA GPU

```fish
# Find your DRM card path
ls /run/udev/data/+drm:*

# Example output:
# /run/udev/data/+drm:card0-DP-4
# /run/udev/data/+drm:card1-DP-1  <- Your primary GPU's first display

# Uncomment these in your launcher script:
set -gx LIBVA_DRIVER_NAME nvidia
set -gx __GLX_VENDOR_LIBRARY_NAME nvidia
set -gx NVD_BACKEND direct
```

### AMD GPU

```fish
# Find your DRM card path
ls /run/udev/data/+drm:*

# Uncomment this in your launcher script:
set -gx LIBVA_DRIVER_NAME radeonsi
# AMD typically doesn't need the other NVIDIA-specific vars
```

### Intel GPU

```fish
# Find your DRM card path
ls /run/udev/data/+drm:*

# Uncomment this in your launcher script:
set -gx LIBVA_DRIVER_NAME iHD
# Intel typically doesn't need other vars
```

### Hybrid GPU (NVIDIA + AMD iGPU)

The launcher script **automatically prefers discrete GPUs** over integrated GPUs:

1. **nvidia** driver is checked first (discrete NVIDIA cards)
2. **amdgpu** driver is checked second (discrete AMD or integrated)
3. Falls back to first available if neither found

```fish
# Check which GPU is which
for card in /sys/class/drm/card*; test -d $card/device && echo (basename $card): (readlink $card/device/driver | xargs basename); end

# Example output for NVIDIA 4090 + AMD Ryzen iGPU:
# card0: amdgpu    <- Integrated (skipped)
# card1: nvidia    <- Discrete (preferred!)
```

If auto-detection doesn't work for your setup, override with:

```fish
set -gx HYPR_DRM_PATH /run/udev/data/+drm:card1-DP-1
```

### Keychron Keyboards

Keychron keyboards default to "media mode" where F1-F12 send media keys:

- **Toggle Fn-lock**: Hold `Fn + X + L` for ~3 seconds
- **Verify**: Run `wev` and press F1 - should show keycode 65470

```
[wl_keyboard] key: ... key: 67; state: 1 (pressed)
               sym: F1 (65470), utf8: ''
```

---

## Credential Manager Setup

### The Problem

With autologin, no password is entered at the TTY login stage. This breaks PAM-based credential manager unlocking (kwallet, gnome-keyring) because they need to capture your password.

### The Authentication Chain

```
SDDM Way (password captured):
  SDDM greeter → pam_kwallet5.so captures password
      → Session opens → Wallet auto-unlocks

TTY Autologin Way (no password):
  getty autologin → No password entered → pam_kwallet5.so has nothing
      → hyprlock auth → Only verifies password, doesn't open session
          → Wallet remains locked → Prompt appears
```

### Solutions

#### Option 1: Blank KWallet Password (Recommended)

The simplest solution - wallet auto-unlocks, security relies on hyprlock:

```bash
# Open KWallet Manager
kwalletmanager5

# KWallet → Change Password → Leave new password empty → Save
```

**Tradeoff**: Anyone who gets past hyprlock can access stored credentials. If hyprlock IS your security boundary, this is acceptable.

#### Option 2: Accept Single Password Prompt

Keep kwallet password, accept one prompt per session after unlocking hyprlock.

#### Option 3: Custom hyprlock PAM (Experimental - Probably Doesn't Work)

In theory, you could unlock kwallet during hyprlock auth. In practice, I don't believe this works because hyprlock doesn't call the PAM session phase. But perhaps someone more clever with PAM could figure it out and let us know!

```bash
# Theoretical approach (untested/likely broken):
echo '#%PAM-1.0
# hyprlock with kwallet unlock attempt
auth        include     system-auth
-auth       optional    pam_kwallet5.so
account     include     system-auth
-session    optional    pam_kwallet5.so auto_start force_run
session     optional    pam_permit.so' | sudo tee /etc/pam.d/hyprlock
```

If you get this working, please open an issue or PR!

### gnome-keyring Conflicts

If you get double prompts (kwallet + gnome-keyring):

```bash
# Check if gnome-keyring is required
pacman -Qi gnome-keyring | grep "Required By"

# If only "org.freedesktop.secrets" virtual package needed,
# kwallet can provide this instead:
sudo pacman -Rns gnome-keyring

# kwallet satisfies org.freedesktop.secrets for bitwarden, etc.
```

---

## Verification Commands

After setup, verify everything works:

```bash
# Check SDDM status
systemctl is-enabled sddm  # Should be "disabled"
systemctl is-active sddm   # Should be "inactive"

# Check runtime directory
echo $XDG_RUNTIME_DIR
ls -la $XDG_RUNTIME_DIR

# Check Hyprland is running
pgrep -a Hyprland

# Check kwallet status
qdbus org.kde.kwalletd6 /modules/kwalletd6 org.kde.KWallet.isOpen kdewallet

# Check SSH keys
ssh-add -l  # Should show keys

# Check gnome-keyring is gone
pgrep -a gnome-keyring  # Should be empty if removed

# Check Hyprland logs
cat ~/.hyprland.log | tail -50

# Check current TTY
tty
cat /sys/class/tty/tty0/active
```

---

## Complete File Contents

### hyprland-tty.fish

See the full script in `scripts/fish/hyprland-tty.fish` or the [Phase 1](#phase-1-create-launcher-script) section above.

### hyprland-autostart.fish

```fish
# Hyprland TTY Autostart
# Auto-launches Hyprland on tty1/tty2 login, handles crashes gracefully

# Only on login shell, on tty1 or tty2
if status is-login
    set TTY (tty)
    if string match -q '/dev/tty1' $TTY; or string match -q '/dev/tty2' $TTY
        echo "=== TTY Autostart: Launching Hyprland ==="

        # Attempt to start Hyprland
        ~/.config/hypr/scripts/hyprland-tty.fish

        # If we get here, Hyprland exited/crashed
        set EXIT_CODE $status

        if test $EXIT_CODE -eq 0
            # Clean exit (user logged out) - restart immediately
            echo "Hyprland exited cleanly, restarting..."
            exit 0
        else
            # Crash or error - give time to read
            echo ""
            echo "========================================="
            echo "Hyprland CRASHED with code: $EXIT_CODE"
            echo "========================================="
            echo ""
            echo "Check ~/.hyprland.log for details"
            echo ""
            echo "Restarting in 10 seconds..."
            echo "(Press Ctrl+C to stay in TTY)"
            sleep 10
            exit 0
        end
    end
end
```

### autologin.conf

`/etc/systemd/system/getty@tty1.service.d/autologin.conf`:

```ini
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty -o "-p -f -- \u" --noclear --autologin YOUR_USERNAME %I $TERM
```

Replace `YOUR_USERNAME` with your actual username.

### execs.conf (relevant portion)

```ini
# Pseudo-login screen - lock immediately on boot (no delay!)
exec-once = hyprlock

# Your other startup apps go after hyprlock
# exec-once = sleep 2 && your-app
```

---

## Logout vs Lock Behavior

After this setup, you have two distinct actions:

| Action | Default Keybind | Behavior |
|--------|----------------|----------|
| **Lock** | `$mainMod + L, hyprlock` | hyprlock overlay, session continues, apps keep running |
| **Logout** | `$mainMod + M, exit` | Full Hyprland exit → Run `hyprland` → hyprlock as auth gate, fresh session |

The logout action gives you a fresh session with all `exec-once` commands re-run.

---

## Future Considerations

- **`start-hyprland` wrapper**: Hyprland may introduce a `start-hyprland` wrapper script in the future. If/when this happens, update the launcher script to use it instead of calling `Hyprland` directly.
- **Environment variables**: As Hyprland evolves, more env vars may be set internally. Check release notes when updating. Currently, Hyprland sets `XDG_SESSION_TYPE`, `XDG_CURRENT_DESKTOP`, `XDG_BACKEND`, `MOZ_ENABLE_WAYLAND`, `_JAVA_AWT_WM_NONREPARENTING`, `DISPLAY`, and `WAYLAND_DISPLAY` internally.

---

## Sources

- [Hyprland Wiki: Systemd Start](https://wiki.hypr.land/Useful-Utilities/Systemd-start/)
- [Hyprland Discord](https://discord.gg/hQ9XvMUjjr) - Community support and discussion
- [Arch Wiki: Getty](https://wiki.archlinux.org/title/Getty) - Autologin configuration reference
- [Reddit: Starting Hyprland directly from systemd](https://www.reddit.com/r/hyprland/comments/127m3ef/starting_hyprland_directy_from_systemd_a_guide_to/)
- [Hyprland Issue #4839: VT switching fixes](https://github.com/hyprwm/Hyprland/issues/4839)
- [Hyprland Issue #4850: VT switching freezes](https://github.com/hyprwm/Hyprland/issues/4850)

---

*Last updated: 2025-12-23*
*Tested on: Arch Linux, Hyprland 0.52.2, Fish 3.x, NVIDIA GPU*
*AMD/Intel GPUs: Untested - feedback welcome!*
