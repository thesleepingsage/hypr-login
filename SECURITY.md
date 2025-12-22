# Security Analysis

This document explains exactly what the installer script does, demonstrating it is safe to run.

> **Note:** Line numbers referenced in this document are relative to when it was published. Future updates to the installer may shift line positions, so numbers may be inaccurate at a later date. Use the provided `grep` commands to verify current locations.

## TL;DR

| Aspect | Status |
|--------|--------|
| Root/sudo required | **Yes** - for systemd and SDDM operations only |
| Files modified | User (`~/.config/`) + System (`/etc/systemd/`) |
| Network access | **None** - no downloads, no telemetry |
| Data collection | **None** - no analytics, no phone-home |
| Reversible | **Yes** - `--uninstall` + documented recovery commands |

---

## Threat Model

**This installer changes your boot security model.** You should understand what you're agreeing to:

### What Changes

| Before (SDDM) | After (hypr-login) |
|---------------|-------------------|
| Boot → SDDM login screen → Password → Desktop | Boot → TTY autologin → Hyprland → hyprlock → Password → Desktop |
| Two-factor: physical access + password | Single-factor at boot, then password at hyprlock |

### Acknowledged Trade-offs

1. **TTY Autologin**: Anyone with physical access to your machine can reach the hyprlock screen without a password. This is by design.

2. **Brief Timing Window**: There's a <1 second window between Hyprland launch and hyprlock activation where the desktop is technically accessible.

3. **Physical Access Assumption**: This setup assumes physical access to your machine already implies trust.

### Who Should NOT Use This

- Shared or public machines
- Security-critical environments requiring multi-factor authentication
- Machines where physical access doesn't imply trust

---

## What Gets Modified

### User-Level (no sudo required)

| Path | Action | Purpose |
|------|--------|---------|
| `~/.config/hypr/scripts/hyprland-tty.fish` | Create | Launcher script with GPU env vars |
| `~/.config/fish/conf.d/hyprland-autostart.fish` | Create | Fish hook for auto-launch on TTY |
| `~/.config/hypr/*/execs.conf` | Manual edit | User adds `exec-once = hyprlock` |

### System-Level (requires sudo)

| Path | Action | Purpose |
|------|--------|---------|
| `/etc/systemd/system/getty@tty1.service.d/` | Create dir | Override directory for getty |
| `/etc/systemd/system/getty@tty1.service.d/autologin.conf` | Create | Autologin configuration |
| `sddm.service` | Disable | Prevents SDDM from starting on boot |

**SDDM is disabled, not removed.** It can be re-enabled with a single command.

---

## Script Breakdown: setup.sh

**~1120 lines total** — here's what each section does:

| Lines | Section | What It Does |
|-------|---------|--------------|
| 1-15 | Shebang + header | `set -eu` enables strict error handling |
| 17-61 | Help | `--help` documentation |
| 63-115 | Configuration | Defines paths, modes, variables (no execution) |
| 113-155 | Helper functions | Output formatting, prompts, menus |
| 187-221 | Path normalization | Safe path handling for `~/`, `file://`, etc. |
| 223-254 | Safe file operations | Backup creation, safe removal |
| 256-300 | Detection functions | Check if already installed |
| 302-385 | System detection | Username, GPU, display, config detection |
| 387-473 | GPU classification | Data-driven GPU type detection and selection |
| 475-536 | Present options | Show detected config, get user confirmation |
| 538-605 | Install functions | Copy launcher and fish hook |
| 607-649 | Execs instructions | Guide user to add hyprlock manually |
| 651-698 | Sudo operations | Request sudo, create systemd override |
| 700-805 | Staged testing | Mandatory tty2 test before SDDM disable |
| 807-875 | SDDM cutover | Critical confirmation, disable SDDM |
| 877-937 | Uninstall | Remove all components, re-enable SDDM |
| 939-986 | Update mode | Refresh files, preserve config |
| 988-1085 | Main install | Orchestrates full installation flow |
| 1087-1122 | Entry point | Argument parsing, mode selection |

### Sudo Usage Locations

All sudo operations are explicit and contained:

```bash
# Line 677: Request sudo access (with user confirmation)
sudo -v

# Line 690: Create systemd override directory
sudo mkdir -p "$SYSTEMD_OVERRIDE_DIR"

# Lines 692-696: Write autologin configuration
cat << EOF | sudo tee "$SYSTEMD_OVERRIDE_FILE" > /dev/null

# Line 698: Reload systemd daemon
sudo systemctl daemon-reload

# Lines 722, 844: Start/disable services
sudo systemctl start getty@tty2
sudo systemctl disable sddm
```

---

## Safety Features

| Feature | How It Works | Lines |
|---------|--------------|-------|
| **Staged testing** | MUST test on tty2 before SDDM is disabled | 700-805 |
| **Dry-run mode** | `--dry-run` previews all changes without executing | 68, 119-131 |
| **User confirmation** | Every major action requires y/N prompt | 134-154 |
| **Automatic backups** | Creates timestamped backups before modifying files | 228-239 |
| **Fail-fast** | `set -eu` exits immediately on any error | 17 |
| **Recovery display** | Shows recovery commands before critical operations | 821-826 |
| **Critical confirmation** | Must type "yes" to disable SDDM | 826, 148-154 |

### Staged Testing Gate

The installer **requires** successful testing on tty2 before SDDM is disabled:

1. Installer starts `getty@tty2`
2. User switches to tty2 (Ctrl+Alt+F2)
3. User verifies: Hyprland starts → hyprlock appears → unlock works
4. User returns to tty1 and confirms success
5. **Only then** does SDDM get disabled

If testing fails, the user can troubleshoot without affecting their current boot setup.

---

## What This Script Does NOT Do

- **No hidden network calls** — no curl, wget, or telemetry
- **No credential storage** — passwords handled by sudo and hyprlock only
- **No data collection** — no analytics or phone-home
- **No cron jobs** — no scheduled tasks installed
- **No background services** — no systemd units beyond getty override
- **No arbitrary code execution** — all operations are explicit file copies/writes

---

## Recovery Procedures

### If Hyprland Won't Start

From tty3 (Ctrl+Alt+F3):
```bash
sudo systemctl enable sddm && sudo reboot
```

### If System Won't Boot to TTY

From a Live USB:
```bash
mount /dev/sdXY /mnt  # Your root partition
arch-chroot /mnt
systemctl enable sddm
exit
reboot
```

### Full Uninstall

```bash
./setup.sh --uninstall
```

This removes all installed files and offers to re-enable SDDM.

---

## Verify It Yourself

### Before running — preview changes:
```bash
./setup.sh --dry-run
```

### Check sudo usage:
```bash
grep -n "sudo" setup.sh
# Expected: Only in request_sudo, create_autologin_override,
#           setup_tty2_testing, disable_sddm, uninstall functions
```

### Verify no network access:
```bash
grep -n "curl\|wget\|nc \|netcat\|http" setup.sh
# Expected: (nothing)
```

### Verify file paths are scoped:
```bash
grep -n "rm -rf\|rm -f" setup.sh
# Expected: Only in remove_if_exists function (scoped to specific paths)
```

### After running — check what was installed:
```bash
# User-level files
ls -la ~/.config/hypr/scripts/hyprland-tty.fish
ls -la ~/.config/fish/conf.d/hyprland-autostart.fish

# System-level files
ls -la /etc/systemd/system/getty@tty1.service.d/

# Service status
systemctl is-enabled sddm      # Should be "disabled"
systemctl is-enabled getty@tty1  # Should be "static" or "enabled"
```

### Run the test suite:
```bash
bats tests/setup.bats
# Expected: All tests pass
```

---

## Questions?

If you find any security concerns, please open an issue. This script is intentionally transparent and auditable.
