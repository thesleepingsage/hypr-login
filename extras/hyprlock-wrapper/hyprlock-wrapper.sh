#!/bin/bash
#
# hyprlock-wrapper.sh
# Boot-aware wrapper that uses different configs for login vs manual lock
#
# Problem: When using "path = screenshot" in hyprlock.conf, the first lock
# after boot has nothing to screenshot (blank screen or default wallpaper).
#
# Solution: Use a static wallpaper config for the first lock after boot,
# then switch to the normal config (with screenshot) for subsequent locks.
#
# Usage:
#   Replace "exec-once = hyprlock" with "exec-once = /path/to/hyprlock-wrapper.sh"
#   Or for UWSM: Edit ExecStart in hyprlock.service
#

set -euo pipefail

FLAG_FILE="/tmp/hyprlock-boot-id"
LOGIN_CONFIG="${HYPRLOCK_LOGIN_CONFIG:-$HOME/.config/hypr/hyprlock-login.conf}"
CURRENT_BOOT_ID=$(cat /proc/sys/kernel/random/boot_id)

# Check if flag file exists and contains current boot ID
if [ -f "$FLAG_FILE" ] && [ "$(cat "$FLAG_FILE")" = "$CURRENT_BOOT_ID" ]; then
    # Same boot session - use normal config (with screenshot)
    exec hyprlock
else
    # First run this boot - use login config (with static wallpaper)
    echo "$CURRENT_BOOT_ID" > "$FLAG_FILE"
    exec hyprlock -c "$LOGIN_CONFIG"
fi
