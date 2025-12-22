# Hyprland TTY Autostart
# Auto-launches Hyprland on tty1/tty2 login, handles crashes gracefully
#
# Installation:
#   Copy to ~/.config/fish/conf.d/hyprland-autostart.fish
#   (Fish automatically sources files in conf.d/)

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
            # Crash or error - give time to read logs
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
