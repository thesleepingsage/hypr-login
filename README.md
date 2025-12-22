# SDDM Bypass: TTY Autologin + Hyprlock as Pseudo-Login

A battle-tested guide for replacing SDDM with direct TTY autologin → Hyprland → hyprlock.

> **⚠️ Disclaimer**: This guide is provided as-is. By following these steps, you accept full responsibility for any outcomes. If something breaks, you get to keep both pieces. This setup modifies critical boot components - ensure you understand what you're doing and have recovery options available. The author is not responsible for bricked systems, lost data, existential crises, or any other issues arising from following this guide.

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Architecture](#architecture)
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
| NVIDIA or AMD GPU | GPU-specific DRM paths differ |

---

## Architecture

### File Structure

| File | Purpose |
|------|---------|
| `~/.config/hypr/scripts/hyprland-tty.fish` | Main launcher with env setup, DRM wait, runtime dir wait |
| `~/.config/fish/conf.d/hyprland-autostart.fish` | Fish login hook that triggers the launcher |
| `~/.config/hypr/custom.d/regular/execs.conf` | Contains `exec-once = hyprlock` at the top |
| `/etc/systemd/system/getty@tty1.service.d/autologin.conf` | Systemd override for autologin |

### Boot Sequence Diagram

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

Create `~/.config/hypr/scripts/hyprland-tty.fish`:

```fish
#!/usr/bin/fish

# Hyprland TTY Launcher Script
# Launches Hyprland directly from TTY login with proper environment setup

# Verbose startup for debugging
set TTY (tty)
echo "=== Hyprland TTY Launcher ==="
echo "TTY: $TTY"
echo "User: "(whoami)" (UID: "(id -u)")"

# ──────────────────────────────────────────────────────────────────
# CRITICAL: Wait for DRM to be ready
# ──────────────────────────────────────────────────────────────────
# Find your GPU's DRM path with: ls /run/udev/data/+drm:*
# NVIDIA example: card1-DP-1
# AMD example: card0-DP-1 (varies by setup)
while not test -e /run/udev/data/+drm:card1-DP-1
    echo "Waiting for DRM..."
    sleep 0.2
end

# ──────────────────────────────────────────────────────────────────
# Essential XDG environment variables
# ──────────────────────────────────────────────────────────────────
# Note: XDG_SESSION_TYPE and XDG_CURRENT_DESKTOP are set by Hyprland internally
set -gx XDG_SESSION_CLASS user

# ──────────────────────────────────────────────────────────────────
# CRITICAL: Wait for XDG_RUNTIME_DIR
# ──────────────────────────────────────────────────────────────────
# pam_systemd creates this, but there's a race condition.
# The script may run before systemd-logind creates the directory.
set -l uid (id -u)
set -gx XDG_RUNTIME_DIR /run/user/$uid

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

# ──────────────────────────────────────────────────────────────────
# GPU-specific environment variables
# ──────────────────────────────────────────────────────────────────
# NVIDIA (adjust for your GPU)
set -gx LIBVA_DRIVER_NAME nvidia
set -gx __GLX_VENDOR_LIBRARY_NAME nvidia
set -gx NVD_BACKEND direct

# AMD users: You likely don't need the NVIDIA vars above.
# Instead, you might need:
# set -gx LIBVA_DRIVER_NAME radeonsi

# ──────────────────────────────────────────────────────────────────
# Electron/Chromium apps (Discord, VSCode, Slack, etc.)
# ──────────────────────────────────────────────────────────────────
# SDDM often sets this implicitly. Without it, Electron apps may
# crash or fall back to XWayland.
set -gx ELECTRON_OZONE_PLATFORM_HINT wayland

# ──────────────────────────────────────────────────────────────────
# Cursor theme
# ──────────────────────────────────────────────────────────────────
set -gx XCURSOR_THEME Bibata-Modern-Classic
set -gx XCURSOR_SIZE 24

# ──────────────────────────────────────────────────────────────────
# Qt/Wayland settings
# ──────────────────────────────────────────────────────────────────
set -gx QT_QPA_PLATFORM wayland
set -gx QT_QPA_PLATFORMTHEME kde

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
# Auto-launches Hyprland on tty1/tty2 login, exits on failure for security

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

Before disabling SDDM, test on tty2 while SDDM still works as fallback:

```bash
# Start getty on tty2 for testing
sudo systemctl start getty@tty2

# Switch to tty2
# Press Ctrl+Alt+F2

# Login with your password
# Fish should auto-run the launcher
# Hyprland should start → hyprlock should lock
```

**Known limitation**: You can't run two Hyprland instances simultaneously (GPU contention). If Hyprland is already running on tty1 via SDDM, the tty2 test will fail with a "crash". This is expected.

**Test VT switching** before proceeding:
- Native Ctrl+Alt+F1-F6 should work
- If not working, see [VT Switching Issues](#vt-switching-issues)

### Phase 5: Live Cutover

```bash
# Step 1: Create autologin systemd override
sudo mkdir -p /etc/systemd/system/getty@tty1.service.d

# Replace 'dj' with your username
echo '[Service]
ExecStart=
ExecStart=-/usr/bin/agetty -o "-p -f -- \\u" --noclear --autologin dj %I $TERM' | sudo tee /etc/systemd/system/getty@tty1.service.d/autologin.conf

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

# Re-enable SDDM
sudo systemctl enable sddm
sudo reboot
```

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
sudo reboot
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

| Symptom | Cause | Solution |
|---------|-------|----------|
| Ctrl+Alt+F* does nothing | Keyboard F-keys in media mode | Toggle Fn-lock (Keychron: Fn+X+L for ~3 seconds) |
| Ctrl+Alt+F* does nothing | Keys sending media codes | Verify with `wev` that F1-F6 send keycodes 65470+ |
| Switching works outbound but crashes inbound | Hyprland bug #4839 with custom monitor resolutions | May improve after SDDM bypass; fallback: `sudo chvt N` keybinds |
| Need workaround binds | Native switching unreliable | Add to binds.conf (requires sudoers rule for `chvt`): |

```ini
# Workaround VT switching binds (if native doesn't work)
# Requires: echo "user ALL=(ALL) NOPASSWD: /usr/bin/chvt" | sudo tee /etc/sudoers.d/chvt
bind = CTRL ALT, F1, exec, sudo chvt 1
bind = CTRL ALT, F2, exec, sudo chvt 2
bind = CTRL ALT, F3, exec, sudo chvt 3
# ... etc
```

---

## Shell Compatibility

**This guide uses Fish shell.** Other shells require modifications:

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

### NVIDIA GPU

```fish
# Find your DRM card path
ls /run/udev/data/+drm:*

# Example output:
# /run/udev/data/+drm:card0-DP-4
# /run/udev/data/+drm:card1-DP-1  <- Your primary GPU's first display

# Environment variables (in launcher script)
set -gx LIBVA_DRIVER_NAME nvidia
set -gx __GLX_VENDOR_LIBRARY_NAME nvidia
set -gx NVD_BACKEND direct
```

### AMD GPU

```fish
# Find your DRM card path
ls /run/udev/data/+drm:*

# Environment variables (in launcher script)
set -gx LIBVA_DRIVER_NAME radeonsi
# AMD typically doesn't need the other NVIDIA-specific vars
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

#### Option 3: Custom hyprlock PAM (Experimental)

Attempt to unlock kwallet during hyprlock auth (may not work - hyprlock doesn't call session phase):

```bash
echo '#%PAM-1.0
# hyprlock with kwallet unlock attempt
auth        include     system-auth
-auth       optional    pam_kwallet5.so
account     include     system-auth
-session    optional    pam_kwallet5.so auto_start force_run
session     optional    pam_permit.so' | sudo tee /etc/pam.d/hyprlock
```

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

```fish
#!/usr/bin/fish

# Hyprland TTY Launcher Script
# Launches Hyprland directly from TTY login with proper environment setup

# Verbose startup for debugging
set TTY (tty)
echo "=== Hyprland TTY Launcher ==="
echo "TTY: $TTY"
echo "User: "(whoami)" (UID: "(id -u)")"

# Wait for DRM to be ready (card1 = NVIDIA GPU)
# Find your path with: ls /run/udev/data/+drm:*
while not test -e /run/udev/data/+drm:card1-DP-1
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

# NVIDIA-specific
set -gx LIBVA_DRIVER_NAME nvidia
set -gx __GLX_VENDOR_LIBRARY_NAME nvidia
set -gx NVD_BACKEND direct

# Electron/Chromium apps (SDDM often sets this implicitly)
set -gx ELECTRON_OZONE_PLATFORM_HINT wayland

# Cursor
set -gx XCURSOR_THEME Bibata-Modern-Classic
set -gx XCURSOR_SIZE 24

# Qt/Wayland
set -gx QT_QPA_PLATFORM wayland
set -gx QT_QPA_PLATFORMTHEME kde

# Launch Hyprland - capture output for debugging
echo "Starting Hyprland..."
Hyprland 2>&1 | tee ~/.hyprland.log
set -l exit_code $pipestatus[1]
echo "Hyprland exited with code: $exit_code"
echo "Press Enter to continue..."
read
```

### hyprland-autostart.fish

```fish
# Hyprland TTY Autostart
# Auto-launches Hyprland on tty1/tty2 login, exits on failure for security

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
| **Lock** | `$mainMod + L` | hyprlock overlay, session continues, apps keep running |
| **Logout** | `$mainMod + M` | Full Hyprland exit → auto-restart → hyprlock as auth gate, fresh session |

The logout action gives you a fresh session with all `exec-once` commands re-run.

---

## Future Considerations

- **`start-hyprland` wrapper**: Hyprland may introduce a `start-hyprland` wrapper script in the future. If/when this happens, update the launcher script to use it instead of calling `Hyprland` directly.
- **Environment variables**: As Hyprland evolves, more env vars may be set internally. Check release notes when updating. Currently, Hyprland sets `XDG_SESSION_TYPE`, `XDG_CURRENT_DESKTOP`, `XDG_BACKEND`, `MOZ_ENABLE_WAYLAND`, `_JAVA_AWT_WM_NONREPARENTING`, `DISPLAY`, and `WAYLAND_DISPLAY` internally.

---

## Sources

- [Hyprland Wiki: Systemd Start](https://wiki.hypr.land/Useful-Utilities/Systemd-start/)
- [Reddit: Starting Hyprland directly from systemd](https://www.reddit.com/r/hyprland/comments/127m3ef/starting_hyprland_directy_from_systemd_a_guide_to/)
- [Hyprland Issue #4839: VT switching fixes](https://github.com/hyprwm/Hyprland/issues/4839)
- [Hyprland Issue #4850: VT switching freezes](https://github.com/hyprwm/Hyprland/issues/4850)

---

*Last updated: 2025-12-21*
*Tested on: Arch Linux, Hyprland 0.52.2, Fish 3.x, NVIDIA GPU*
