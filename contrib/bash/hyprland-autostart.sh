# Paste this in ~/.bash_profile

# Hyprland TTY Autostart
# Auto-launches Hyprland on tty1/tty2 login via start-hyprland watchdog
#
# Note: start-hyprland (Hyprland 0.53+) handles crash recovery and safe mode
# internally, so we no longer need a restart loop here.

# Only on login shell, on tty1 or tty2
if shopt -q login_shell; then
    if [[ $(tty) == '/dev/tty1' || $(tty) == '/dev/tty2' ]]; then
        echo "=== TTY Autostart: Launching Hyprland via start-hyprland ==="
        ~/.config/hypr/hyprland-tty.sh
        # start-hyprland handles crash recovery internally
        # If we get here, start-hyprland exited cleanly (user logged out)
    fi
fi