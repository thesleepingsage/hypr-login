# Hyprland TTY Autostart
# Auto-launches Hyprland on tty1/tty2 login via start-hyprland watchdog
#
# Installation:
#   Copy to ~/.config/fish/conf.d/hyprland-autostart.fish
#   (Fish automatically sources files in conf.d/)
#
# Note: start-hyprland (Hyprland 0.53+) handles crash recovery and safe mode
# internally, so we no longer need a restart loop here.

# Only on login shell, on tty1 or tty2
if status is-login
    set -l tty (tty)
    if string match -q '/dev/tty1' $tty; or string match -q '/dev/tty2' $tty
        echo "=== TTY Autostart: Launching Hyprland via start-hyprland ==="
        ~/.config/hypr/scripts/hyprland-tty.fish
        # start-hyprland handles crash recovery internally
        # If we get here, start-hyprland exited cleanly (user logged out)
    end
end
