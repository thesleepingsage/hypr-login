# Hyprlock Wrapper - Boot-Aware Lock Screen

A wrapper script that uses different hyprlock configurations for login (first lock after boot) vs manual locks (subsequent locks during the session).

## The Problem

If your `hyprlock.conf` uses `path = screenshot` for the background, the first lock screen after boot has nothing meaningful to screenshot. You'll see:

- The default Hyprland wallpaper (if `misc:force_default_wallpaper` is set)
- A blank/black screen
- The anime girl wallpaper (if `force_default_wallpaper = 2`)

This looks unprofessional and defeats the purpose of a nice lock screen.

## The Solution

Use two configs:
1. **hyprlock-login.conf** - Uses a static wallpaper (for boot lock)
2. **hyprlock.conf** - Uses `path = screenshot` (for manual locks)

The wrapper script detects whether this is the first lock since boot and chooses the appropriate config.

## Installation

### Step 1: Copy the wrapper script

```bash
mkdir -p ~/.config/hypr/scripts
cp hyprlock-wrapper.sh ~/.config/hypr/scripts/
chmod +x ~/.config/hypr/scripts/hyprlock-wrapper.sh
```

### Step 2: Create your login config

Copy your existing hyprlock.conf and modify the background:

```bash
cp ~/.config/hypr/hyprlock.conf ~/.config/hypr/hyprlock-login.conf
```

Then edit `hyprlock-login.conf` and change:
```conf
background {
    path = screenshot  # Change this line
}
```
to:
```conf
background {
    path = /path/to/your/wallpaper.jpg  # Static image
}
```

### Step 3: Update how hyprlock starts

#### For exec-once users (Direct/TTY method):

In your execs.conf, replace:
```conf
exec-once = hyprlock
```
with:
```conf
exec-once = ~/.config/hypr/scripts/hyprlock-wrapper.sh
```

#### For UWSM users (systemd service method):

Edit your hyprlock.service:
```bash
mkdir -p ~/.config/systemd/user/hyprlock.service.d
cat > ~/.config/systemd/user/hyprlock.service.d/override.conf << 'EOF'
[Service]
ExecStart=
ExecStart=/home/YOUR_USERNAME/.config/hypr/scripts/hyprlock-wrapper.sh
EOF
systemctl --user daemon-reload
```

## How It Works

The wrapper uses the kernel's `boot_id` (from `/proc/sys/kernel/random/boot_id`) to detect boot cycles. This ID is unique per boot - even if the system crashes and restarts, you get a new ID.

1. On first run after boot: Saves boot_id to `/tmp/hyprlock-boot-id`, uses login config
2. On subsequent runs: Checks if boot_id matches, uses normal config (screenshot)

## Configuration

You can customize the login config path with an environment variable:

```bash
HYPRLOCK_LOGIN_CONFIG=~/.config/hypr/my-custom-login.conf ~/.config/hypr/scripts/hyprlock-wrapper.sh
```

## Related: force_default_wallpaper

If you see the anime girl or numbered wallpapers, check your Hyprland config:

```conf
misc {
    force_default_wallpaper = 0  # Disable default wallpapers
    disable_hyprland_logo = true
}
```

- `-1` = random default wallpaper
- `0` = no default wallpaper
- `1` = default wallpaper without anime
- `2` = anime girl wallpaper
