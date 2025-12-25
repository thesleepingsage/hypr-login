#!/bin/bash
#
# setup.sh
# Interactive installer for hypr-login (TTY autologin with hyprlock)
#
# Usage:
#   ./setup.sh           # Interactive install
#   ./setup.sh -n        # Dry-run (preview changes)
#   ./setup.sh -u        # Uninstall
#   ./setup.sh -d        # Update existing installation
#   ./setup.sh -h        # Show help
#
# Config file (optional):
#   ~/.config/hypr-login/install.conf
#

set -euo pipefail

# ============================================================================
# SECTION 1: Help
# ============================================================================

show_help() {
    cat << 'EOF'
setup.sh - Interactive installer for hypr-login

USAGE:
    ./setup.sh [OPTIONS]

OPTIONS:
    -h, --help       Show this help message
    -n, --dry-run    Preview changes without modifying files
    -u, --uninstall  Remove all installed components
    -d, --update     Update existing installation (preserves config)
    --skip-test      Skip staged testing (NOT RECOMMENDED)

DESCRIPTION:
    Installs hypr-login, which replaces your display manager (SDDM) with
    a faster boot chain: TTY autologin → Hyprland → hyprlock

    The installer will:
    1. Detect your system configuration (GPU, username, etc.)
    2. Present options for you to confirm
    3. Install user-level components (scripts, Fish hook)
    4. Show instructions for adding hyprlock to your config
    5. Configure systemd autologin (requires sudo)
    6. Guide you through staged testing on tty2
    7. Only disable SDDM after successful test

CONFIG FILE:
    Optional: ~/.config/hypr-login/install.conf
    Pre-configure settings to skip interactive prompts.

RECOVERY:
    If something goes wrong after installation:
    - From tty3: sudo systemctl enable sddm && sudo reboot
    - From Live USB: arch-chroot /mnt systemctl enable sddm

EOF
    exit 0
}

# ============================================================================
# SECTION 2: Configuration & Modes
# ============================================================================

# Modes
DRY_RUN=false
UNINSTALL=false
UPDATE_MODE=false
SKIP_TEST=false

# Timeouts (seconds) - tune for slow systems if needed
readonly SYSTEMCTL_DEFAULT_TIMEOUT=5   # Default for systemctl operations
readonly SYSTEMCTL_VERIFY_TIMEOUT=3    # Quick status/config checks
readonly SUDO_AUTH_TIMEOUT=60          # Time for user to enter sudo password

# Script directory (where this script lives)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Installation paths
LAUNCHER_DEST="$HOME/.config/hypr/scripts/hyprland-tty.fish"
FISH_HOOK_DEST="$HOME/.config/fish/conf.d/hyprland-autostart.fish"
SYSTEMD_OVERRIDE_DIR="/etc/systemd/system/getty@tty1.service.d"
SYSTEMD_OVERRIDE_DEST="$SYSTEMD_OVERRIDE_DIR/autologin.conf"
CONFIG_DIR="$HOME/.config/hypr-login"
CONFIG_FILE="$CONFIG_DIR/install.conf"

# Source files
LAUNCHER_SRC="$SCRIPT_DIR/scripts/fish/hyprland-tty.fish"
FISH_HOOK_SRC="$SCRIPT_DIR/scripts/fish/hyprland-autostart.fish"

# Detected values (populated during detection phase)
# Lifecycle: Set by detect_* functions in install_detect_system()
#            Consumed by present_* and install_* functions
#            Persisted to CONFIG_FILE by save_install_config()
#            Restored by load_install_config() in update mode
DETECTED_USERNAME=""      # Current username for autologin
DETECTED_GPU_TYPE=""      # nvidia|amd|intel|auto
DETECTED_GPUS=()          # Array of "cardN:driver" pairs
DETECTED_DRM_PATH=""      # auto or /run/udev/data/+drm:cardN-OUTPUT
DETECTED_OUTPUTS=()       # Array of display output paths
DETECTED_EXECS_FILES=()   # Array of execs*.conf file paths
HYPRLOCK_CONFIGURED_FILES=()  # Files already containing hyprlock config
HYPR_CONFIG_DIR=""        # Path to ~/.config/hypr

# Session method: "exec-once" (TTY/direct) or "uwsm" (systemd service)
SESSION_METHOD=""

# Hyprlock service paths (for UWSM method)
HYPRLOCK_SERVICE_SRC="$SCRIPT_DIR/configs/systemd/user/hyprlock.service"
HYPRLOCK_SERVICE_DEST="$HOME/.config/systemd/user/hyprlock.service"

# ============================================================================
# SECTION 3: Colors
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# ============================================================================
# SECTION 4: Interrupt Handling
# ============================================================================

# Track if we're in the middle of a critical operation
CRITICAL_OPERATION=""

cleanup_on_interrupt() {
    local exit_code=$?
    echo ""
    echo -e "${RED}[INTERRUPTED]${NC} Script was interrupted"

    if [[ -n "$CRITICAL_OPERATION" ]]; then
        echo -e "${YELLOW}[WARN]${NC} Interrupted during: $CRITICAL_OPERATION"
        echo ""
        echo "  The installation may be in a partial state."
        echo "  To clean up, run: ./setup.sh -u"
        echo "  To retry, run: ./setup.sh"
    fi

    # Terminate any child processes (including sudo commands)
    # Use SIGTERM first for graceful shutdown
    local children
    children=$(jobs -p 2>/dev/null)
    if [[ -n "$children" ]]; then
        # shellcheck disable=SC2086
        kill -TERM $children 2>/dev/null || true
        sleep 0.5
        # Force kill any remaining
        # shellcheck disable=SC2086
        kill -KILL $children 2>/dev/null || true
    fi

    # Also kill any direct child processes not captured by jobs
    pkill -TERM -P $$ 2>/dev/null || true

    # Clean up any temp files that might exist (use XDG_RUNTIME_DIR to match creation path)
    if [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
        rm -f "$XDG_RUNTIME_DIR"/hypr-login-*.tmp 2>/dev/null || true
    fi
    rm -f /tmp/hypr-login-*.tmp 2>/dev/null || true  # Fallback for edge cases

    exit $exit_code
}

# Trap is set after acquiring lock (line 190) to ensure lock release on interrupt

# ============================================================================
# SECTION 5: Concurrent Execution Lock
# ============================================================================

# Prevent multiple instances from running simultaneously
# Use XDG_RUNTIME_DIR if available (per-user, tmpfs), fallback to /tmp
LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/hypr-login-install.lock"
acquire_lock() {
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        error "Another hypr-login installation is already running"
        echo "  If this is incorrect, remove: $LOCK_FILE"
        exit 1
    fi
}
acquire_lock
# Single trap handles both lock release AND cleanup (avoids trap overwrite issue)
trap 'flock -u 200 2>/dev/null; cleanup_on_interrupt' INT TERM

# ============================================================================
# SECTION 6: Helper Functions
# ============================================================================

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# Safe systemctl wrapper with timeout and consistent error handling
# Usage: systemctl_safe [--user] [--sudo] [--quiet] [--timeout=N] <action> [unit]
# Returns: 0 on success, 1 on failure/timeout
# Examples:
#   systemctl_safe --user daemon-reload
#   systemctl_safe --sudo disable sddm
#   systemctl_safe --user --quiet is-active hyprlock.service
systemctl_safe() {
    local use_user=false use_sudo=false quiet=false timeout_sec="$SYSTEMCTL_DEFAULT_TIMEOUT"
    local args=()

    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --user)      use_user=true; shift ;;
            --sudo)      use_sudo=true; shift ;;
            --quiet)     quiet=true; shift ;;
            --timeout=*) timeout_sec="${1#--timeout=}"; shift ;;
            *)           args+=("$1"); shift ;;
        esac
    done

    # Build command
    local cmd=()
    $use_sudo && cmd+=(sudo)
    cmd+=(timeout "$timeout_sec" systemctl)
    $use_user && cmd+=(--user)
    cmd+=("${args[@]}")

    # Execute with appropriate output handling
    if $quiet; then
        "${cmd[@]}" >/dev/null 2>&1
    else
        "${cmd[@]}"
    fi
}

dry_run_prefix() {
    if $DRY_RUN; then
        echo -e "${CYAN}[DRY-RUN]${NC} "
    fi
}

# Returns 0 (true) in dry-run mode, 1 otherwise
dry_run_preview() {
    $DRY_RUN || return 1
    for msg in "$@"; do
        echo "$(dry_run_prefix)$msg"
    done
    return 0
}

# Default: No
ask() {
    echo -e -n "${YELLOW}[?]${NC} $1 [y/N] "
    read -r response
    [[ "$response" =~ ^[Yy]$ ]]
}

# Default: Yes
ask_yes() {
    echo -e -n "${YELLOW}[?]${NC} $1 [Y/n] "
    read -r response
    [[ ! "$response" =~ ^[Nn]$ ]]
}

# Require typing full word for critical confirmations
ask_critical() {
    local prompt="$1"
    local required_word="${2:-yes}"
    echo -e -n "${RED}[!]${NC} $prompt (type '${BOLD}$required_word${NC}' to confirm): "
    read -r response
    [[ "$response" == "$required_word" ]]
}

# Display a numbered menu and get user selection
# Usage: result=$(select_from_menu "Choose:" "opt1" "opt2")
# Returns: Echoes selected value to stdout, returns 0 on valid selection
# Note: Menu is displayed to stderr so it shows on screen but isn't captured
select_from_menu() {
    local prompt="$1"
    shift
    local options=("$@")
    local i=1

    for opt in "${options[@]}"; do
        echo "    $i) $opt" >&2
        ((i++))
    done
    echo "" >&2
    echo -n "  $prompt [1-${#options[@]}]: " >&2
    read -r choice

    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#options[@]} ]]; then
        echo "${options[$((choice-1))]}"  # Output to stdout for capture
        return 0
    else
        return 1
    fi
}

# Find a working editor: EDITOR env var first, then fallback to common editors
# Sets: FOUND_EDITOR (global) to the editor command if found
# Returns: 0 if editor found, 1 if not
FOUND_EDITOR=""
find_editor() {
    FOUND_EDITOR=""

    # Prefer $EDITOR if set and executable
    if [[ -n "${EDITOR:-}" ]] && command -v "$EDITOR" >/dev/null 2>&1; then
        FOUND_EDITOR="$EDITOR"
        return 0
    fi

    # Fallback to common editors
    for candidate in nano vim nvim vi; do
        if command -v "$candidate" >/dev/null 2>&1; then
            FOUND_EDITOR="$candidate"
            return 0
        fi
    done

    return 1
}

# ============================================================================
# SECTION 7: Path Normalization
# ============================================================================

# Normalize any path to absolute form
# Handles: ~/, $HOME, file://, relative paths, trailing slashes
normalize_path() {
    local path="$1"

    # Strip file:// prefix (from file pickers, drag-drop, etc.)
    path="${path#file://}"

    # Expand ~ to $HOME (must be at start)
    if [[ "$path" == "~" ]]; then
        path="$HOME"
    elif [[ "$path" == "~/"* ]]; then
        path="$HOME/${path#\~/}"
    fi

    # Expand $HOME if literally present in string
    path="${path//\$HOME/$HOME}"

    # Convert to absolute path if relative
    if [[ "$path" != /* ]]; then
        path="$(pwd)/$path"
    fi

    # Normalize the path (resolve .., remove double slashes, etc.)
    path="$(readlink -m "$path" 2>/dev/null || echo "$path")"

    # Remove trailing slash (unless it's root /)
    [[ "$path" != "/" ]] && path="${path%/}"

    echo "$path"
}

# ============================================================================
# SECTION 8: Safe File Operations
# ============================================================================

# Create timestamped backup
backup_file() {
    local file="$1"
    # Use nanoseconds to prevent timestamp collision on rapid calls
    local backup
    backup="${file}.backup.$(date +%Y%m%d_%H%M%S_%N)" || { error "Failed to generate backup timestamp"; return 1; }

    if [[ -f "$file" ]]; then
        if dry_run_preview "Would backup: $file → $backup"; then
            return 0
        fi
        # Use -p to preserve permissions (important for executables)
        cp -p "$file" "$backup" || { error "Failed to backup: $file"; return 1; }
        info "Backup created: $backup"
    fi
}

# Remove file/dir if exists
remove_if_exists() {
    local path="$1"
    local description="$2"

    [[ -e "$path" ]] || [[ -L "$path" ]] || return 0

    if $DRY_RUN; then
        echo "$(dry_run_prefix)Would remove: $path"
    else
        rm -rf "$path" || { error "Failed to remove: $path"; return 1; }
        success "Removed $description"
    fi
}

# Validate XDG_RUNTIME_DIR is available for secure temp file handling
# Returns: 0 if valid, 1 if missing/invalid (with error message)
validate_xdg_runtime_dir() {
    if [[ -z "${XDG_RUNTIME_DIR:-}" ]] || [[ ! -d "$XDG_RUNTIME_DIR" ]]; then
        error "XDG_RUNTIME_DIR not set or invalid - required for secure temp file handling"
        echo "  This is typically set by systemd-logind on login."
        return 1
    fi
}

# Install a file atomically using temp file + install -T pattern
# Args: $1 = source, $2 = destination, $3 = mode (e.g., 755), $4 = description
# Optional: Set INSTALL_CONFIG_FUNC to a function name to call on temp file before install
# Returns: 0 on success, 1 on failure
INSTALL_CONFIG_FUNC=""
install_file_atomically() {
    local src="$1"
    local dest="$2"
    local mode="$3"
    local desc="${4:-file}"
    local dest_dir

    dest_dir="$(dirname "$dest")"

    if dry_run_preview "Would create: $dest"; then
        return 0
    fi

    mkdir -p "$dest_dir" || { error "Failed to create directory: $dest_dir"; return 1; }
    validate_xdg_runtime_dir || return 1

    # Use temp file for atomic operations
    local temp_file
    temp_file=$(mktemp "$XDG_RUNTIME_DIR/hypr-login-XXXXXX.tmp") || { error "Failed to create temp file"; return 1; }
    trap 'rm -f "$temp_file"' RETURN

    cp "$src" "$temp_file" || { error "Failed to copy $desc"; return 1; }

    # Apply optional configuration function
    if [[ -n "$INSTALL_CONFIG_FUNC" ]]; then
        "$INSTALL_CONFIG_FUNC" "$temp_file" || return 1
    fi

    # Install atomically (install -T prevents symlink attacks)
    install -T -m "$mode" "$temp_file" "$dest" || { error "Failed to install $desc"; return 1; }
    trap - RETURN  # Clear trap since install succeeded

    success "${desc^} installed: $dest"
}

# ============================================================================
# SECTION 9: Installation Detection
# ============================================================================

is_launcher_installed() {
    [[ -f "$LAUNCHER_DEST" ]]
}

is_fish_hook_installed() {
    [[ -f "$FISH_HOOK_DEST" ]]
}

is_systemd_configured() {
    # Check file exists and is not empty
    [[ -s "$SYSTEMD_OVERRIDE_DEST" ]] || return 1

    # Validate it contains the autologin flag (core functionality)
    grep -q -- '--autologin' "$SYSTEMD_OVERRIDE_DEST" || return 1

    # Ensure placeholder was replaced (not still "YOUR_USERNAME")
    ! grep -q 'YOUR_USERNAME' "$SYSTEMD_OVERRIDE_DEST"
}

is_hyprlock_service_installed() {
    [[ -f "$HYPRLOCK_SERVICE_DEST" ]]
}

is_fully_installed() {
    # Check core components plus config file
    is_launcher_installed && \
    is_fish_hook_installed && \
    is_systemd_configured && \
    [[ -f "$CONFIG_FILE" ]]
}

is_sddm_enabled() {
    systemctl_safe --timeout="$SYSTEMCTL_VERIFY_TIMEOUT" --quiet is-enabled sddm
}

# Save installation configuration for future updates
save_install_config() {
    if dry_run_preview "Would save config to: $CONFIG_FILE"; then
        return 0
    fi

    mkdir -p "$CONFIG_DIR" || { error "Failed to create config directory"; return 1; }

    if ! cat > "$CONFIG_FILE" <<EOF
# hypr-login installation configuration
# Generated: $(date -Iseconds)
SESSION_METHOD=$SESSION_METHOD
GPU_TYPE=$DETECTED_GPU_TYPE
DRM_PATH=$DETECTED_DRM_PATH
EOF
    then
        error "Failed to write config file"
        return 1
    fi

    # Validate the file was actually written and is not empty
    if [[ ! -s "$CONFIG_FILE" ]]; then
        error "Config file is empty or missing after write"
        return 1
    fi

    # Restrict permissions - config contains system info
    chmod 600 "$CONFIG_FILE" || { error "Failed to set config file permissions"; return 1; }

    success "Saved installation config to $CONFIG_FILE"
}

# Load installation configuration from previous install
# Security: Uses grep extraction instead of sourcing to prevent TOCTOU attacks
# where a malicious file could be swapped in between validation and execution
load_install_config() {
    [[ -f "$CONFIG_FILE" ]] || return 1
    [[ -r "$CONFIG_FILE" ]] || { warn "Config file not readable: $CONFIG_FILE"; return 1; }
    [[ -s "$CONFIG_FILE" ]] || { warn "Config file is empty: $CONFIG_FILE"; return 1; }

    # Extract values via grep (safe - no code execution)
    local loaded_session loaded_gpu loaded_drm
    local values_loaded=0
    loaded_session=$(grep -E "^SESSION_METHOD=" "$CONFIG_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
    loaded_gpu=$(grep -E "^GPU_TYPE=" "$CONFIG_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
    loaded_drm=$(grep -E "^DRM_PATH=" "$CONFIG_FILE" 2>/dev/null | head -1 | cut -d= -f2-)

    # Validate SESSION_METHOD against strict allowlist
    if [[ "$loaded_session" == "exec-once" || "$loaded_session" == "uwsm" ]]; then
        SESSION_METHOD="$loaded_session"
        ((values_loaded++))
    elif [[ -n "$loaded_session" ]]; then
        warn "Invalid SESSION_METHOD in config: $loaded_session"
    fi

    # Validate GPU_TYPE against known values
    if [[ "$loaded_gpu" =~ ^(nvidia|amd|intel|auto)$ ]]; then
        DETECTED_GPU_TYPE="$loaded_gpu"
        ((values_loaded++))
    elif [[ -n "$loaded_gpu" ]]; then
        warn "Invalid GPU_TYPE in config: $loaded_gpu"
    fi

    # Validate DRM_PATH format (or auto)
    if [[ "$loaded_drm" == "auto" ]] || [[ "$loaded_drm" =~ ^/run/udev/data/\+drm:card[0-9]+-[A-Za-z0-9_-]+$ ]]; then
        DETECTED_DRM_PATH="$loaded_drm"
        ((values_loaded++))
    elif [[ -n "$loaded_drm" ]]; then
        warn "Invalid DRM_PATH in config: $loaded_drm"
    fi

    # Return success only if ALL expected values were loaded
    # Partial loads indicate corruption - better to re-detect than use incomplete config
    if [[ $values_loaded -eq 3 ]]; then
        return 0
    elif [[ $values_loaded -gt 0 ]]; then
        warn "Config incomplete ($values_loaded/3 values) - will re-detect missing settings"
        return 0  # Still return success, but user is warned
    else
        return 1
    fi
}

# ============================================================================
# SECTION 10: Pre-flight Validation
# ============================================================================

validate_dependencies() {
    local missing=()

    command -v fish &>/dev/null || missing+=("fish")
    command -v Hyprland &>/dev/null || missing+=("Hyprland")
    command -v hyprlock &>/dev/null || missing+=("hyprlock")

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing dependencies: ${missing[*]}"
        echo ""
        echo "  Install with: sudo pacman -S ${missing[*]}"
        echo ""
        exit 1
    fi

    success "All dependencies found (fish, Hyprland, hyprlock)"

    # Verify date supports nanoseconds (used for unique backup filenames)
    # Some minimal/busybox systems may not support %N
    local nano_test
    nano_test=$(date +%N 2>/dev/null) || nano_test=""
    if [[ -z "$nano_test" ]] || [[ "$nano_test" == "%N" ]] || [[ "$nano_test" == "N" ]]; then
        warn "System date doesn't support nanoseconds (%N) - backup filenames may collide"
        echo "  This is usually fine unless you run rapid sequential backups"
    fi
}

# Validate a file exists, is non-empty, and is readable
# Args: $1 = path, $2 = description (optional, defaults to "Source file")
# Returns: 1 on any failure (with error message), 0 on success
validate_file() {
    local path="$1"
    local desc="${2:-Source file}"

    if [[ ! -f "$path" ]]; then
        error "$desc not found: $path"
        return 1
    fi
    if [[ ! -s "$path" ]]; then
        error "$desc is empty: $path"
        return 1
    fi
    if [[ ! -r "$path" ]]; then
        error "$desc not readable: $path"
        return 1
    fi
}

validate_source_files() {
    if ! validate_file "$LAUNCHER_SRC" "Launcher script"; then
        echo "  Make sure you're running from the hypr-login directory"
        exit 1
    fi
    if ! validate_file "$FISH_HOOK_SRC" "Fish hook script"; then
        exit 1
    fi
    success "Source files found and verified"
}

# ============================================================================
# SECTION 11: System Detection
# Functions that populate DETECTED_* globals by inspecting the system
# ============================================================================

# Detect the username for autologin configuration
# Sets: DETECTED_USERNAME
# Blocks root execution, handles sudo invocation
detect_username() {
    # Safety check: block if running as actual root (not via sudo)
    # Use ${SUDO_USER:-} to handle unset variable with set -u
    if [[ $(whoami) == "root" && -z "${SUDO_USER:-}" ]]; then
        error "This script should not be run as root"
        error "Run as your normal user - it will request sudo when needed"
        exit 1
    fi

    # If run with sudo, warn but use the original invoking user
    if [[ -n "${SUDO_USER:-}" ]]; then
        warn "Running with sudo detected - using original user: $SUDO_USER"
        warn "Tip: Run without sudo next time (script requests sudo when needed)"
        DETECTED_USERNAME="$SUDO_USER"
    else
        DETECTED_USERNAME=$(whoami)
    fi
}

# Detect available GPUs by scanning /sys/class/drm
# Sets: DETECTED_GPUS (array of "cardN:driver" pairs)
detect_gpus() {
    DETECTED_GPUS=()

    for card_dir in /sys/class/drm/card*; do
        [[ -d "$card_dir/device" ]] || continue

        local card_name
        card_name="$(basename "$card_dir")"

        # Only base cards (card0, card1), not outputs (card0-DP-1)
        [[ "$card_name" =~ ^card[0-9]+$ ]] || continue

        local driver_path driver_name
        driver_path="$(readlink -f "$card_dir/device/driver" 2>/dev/null || echo "unknown")"
        driver_name="$(basename "$driver_path")"

        DETECTED_GPUS+=("$card_name:$driver_name")
    done
}

# Detect available display outputs from udev data
# Sets: DETECTED_OUTPUTS (array of DRM output paths)
detect_display_outputs() {
    DETECTED_OUTPUTS=()

    for drm_file in /run/udev/data/+drm:card*-*; do
        [[ -e "$drm_file" ]] || continue
        DETECTED_OUTPUTS+=("$drm_file")
    done
}

# Detect Hyprland configuration directory and exec configs
# Sets: HYPR_CONFIG_DIR, DETECTED_EXECS_FILES
detect_hyprland_config() {
    # Respect XDG_CONFIG_HOME (defaults to ~/.config if not set)
    local config_base="${XDG_CONFIG_HOME:-$HOME/.config}"
    HYPR_CONFIG_DIR=$(normalize_path "$config_base/hypr")
    DETECTED_EXECS_FILES=()

    [[ -d "$HYPR_CONFIG_DIR" ]] || return

    # Find all execs*.conf files
    while IFS= read -r -d '' file; do
        DETECTED_EXECS_FILES+=("$file")
    done < <(find "$HYPR_CONFIG_DIR" -name "execs*.conf" -print0 2>/dev/null | sort -z)
}

# Scan config files for existing hyprlock exec-once lines
# Populates: HYPRLOCK_CONFIGURED_FILES[]
detect_hyprlock_in_config() {
    HYPRLOCK_CONFIGURED_FILES=()

    [[ ${#DETECTED_EXECS_FILES[@]} -eq 0 ]] && return

    for file in "${DETECTED_EXECS_FILES[@]}"; do
        [[ -f "$file" ]] || continue

        # Match: exec-once = hyprlock (with optional spaces, arguments, or semicolons)
        # Exclude: commented lines (# at start, possibly with leading whitespace)
        # Pattern handles: hyprlock, hyprlock;, hyprlock --arg, hyprlock &
        if grep -qE '^[^#]*exec-once\s*=\s*hyprlock(\s|;|&|$)' "$file" 2>/dev/null; then
            HYPRLOCK_CONFIGURED_FILES+=("$file")
        fi
    done
}

# Check if hyprlock is currently running
is_hyprlock_running() {
    pgrep -x hyprlock >/dev/null 2>&1
}

# ============================================================================
# SECTION 12: Present Detection Results
# ============================================================================

present_username() {
    echo ""
    info "Username: $DETECTED_USERNAME"

    if ! ask_yes "Use this username for autologin?"; then
        while true; do
            echo -n "Enter username: "
            read -r DETECTED_USERNAME

            if [[ -z "$DETECTED_USERNAME" ]]; then
                warn "Username cannot be empty"
                continue
            fi

            if ! id "$DETECTED_USERNAME" &>/dev/null; then
                warn "User '$DETECTED_USERNAME' does not exist"
                continue
            fi
            break
        done
    fi

    success "Username confirmed: $DETECTED_USERNAME"
}

# Driver name → "value:Label" mapping for GPU detection
# Add new GPU vendors here (driver name from /sys/class/drm/cardN/device/driver)
declare -A GPU_DRIVER_MAP=(
    [nvidia]="nvidia:NVIDIA"
    [amdgpu]="amd:AMD"
    [i915]="intel:Intel"
)

# Display detected GPUs and show warnings
# Returns: unknown_drivers array and driver_count associative array via globals
# Used by: classify_detected_gpus()
display_detected_gpus() {
    _GPU_UNKNOWN_DRIVERS=()
    declare -gA _GPU_DRIVER_COUNT=()
    local -A _unknown_seen=()  # For deduplication (consistent with build_gpu_types_list pattern)

    for gpu in "${DETECTED_GPUS[@]}"; do
        local card="${gpu%%:*}"
        local driver="${gpu##*:}"

        # Track driver occurrences for duplicate detection
        ((_GPU_DRIVER_COUNT[$driver]++)) || _GPU_DRIVER_COUNT[$driver]=1

        # Display with card number prominently
        if [[ -v "GPU_DRIVER_MAP[$driver]" ]]; then
            local label="${GPU_DRIVER_MAP[$driver]##*:}"
            echo "    • $card: $label ($driver driver)"
        else
            echo "    • $card: $driver (unknown driver)"
            # Use associative array for O(1) dedup (consistent with build_gpu_types_list)
            if [[ ! -v "_unknown_seen[$driver]" ]]; then
                _GPU_UNKNOWN_DRIVERS+=("$driver")
                _unknown_seen[$driver]=1
            fi
        fi
    done

    # Warn about unrecognized GPU drivers
    if [[ ${#_GPU_UNKNOWN_DRIVERS[@]} -gt 0 ]]; then
        echo ""
        warn "Unrecognized GPU driver(s): ${_GPU_UNKNOWN_DRIVERS[*]}"
        echo "      Known drivers: ${!GPU_DRIVER_MAP[*]}"
        echo "      GPU env vars will use auto-detection for unknown drivers"
    fi

    # Check for duplicate GPU types (e.g., two NVIDIA cards)
    for driver in "${!_GPU_DRIVER_COUNT[@]}"; do
        if [[ ${_GPU_DRIVER_COUNT[$driver]} -gt 1 ]] && [[ -v "GPU_DRIVER_MAP[$driver]" ]]; then
            echo ""
            info "Multiple ${GPU_DRIVER_MAP[$driver]##*:} GPUs detected (${_GPU_DRIVER_COUNT[$driver]} cards)"
            echo "      Pay attention to Display Output selection to target the correct card"
        fi
    done
}

# Build GPU types list from detected GPUs (pure data transformation)
# Sets: GPU_TYPES_IN_ORDER (array of "value:Label" pairs in detection order), GPU_TYPE_COUNT
build_gpu_types_list() {
    GPU_TYPES_IN_ORDER=()
    GPU_TYPE_COUNT=0
    local -A seen=()

    for gpu in "${DETECTED_GPUS[@]}"; do
        local driver="${gpu##*:}"

        # Add to list if known driver and not yet seen
        if [[ -v "GPU_DRIVER_MAP[$driver]" ]] && [[ ! -v "seen[$driver]" ]]; then
            GPU_TYPES_IN_ORDER+=("${GPU_DRIVER_MAP[$driver]}")
            seen[$driver]=1
            ((++GPU_TYPE_COUNT))
        fi
    done
}

# Classify detected GPUs and display them
# Orchestrates display and classification
# Sets: GPU_TYPES_IN_ORDER, GPU_TYPE_COUNT
GPU_TYPES_IN_ORDER=()
GPU_TYPE_COUNT=0
classify_detected_gpus() {
    display_detected_gpus
    build_gpu_types_list
}

# Prompt user to select primary GPU when multiple types detected
# Sets: DETECTED_GPU_TYPE
select_primary_gpu() {
    echo "  Multiple GPU types detected. Which is your primary GPU?"
    echo ""
    local options=() i=1
    for gpu_entry in "${GPU_TYPES_IN_ORDER[@]}"; do
        local value="${gpu_entry%%:*}"
        local label="${gpu_entry##*:}"
        options+=("$value")
        echo "    $i) $label"
        ((i++))
    done
    echo ""

    while true; do
        echo -n "  Choose [1-${#options[@]}]: "
        read -r gpu_choice || { warn "Input cancelled"; return 1; }

        if [[ "$gpu_choice" =~ ^[0-9]+$ ]] && [[ "$gpu_choice" -ge 1 ]] && [[ "$gpu_choice" -le ${#options[@]} ]]; then
            DETECTED_GPU_TYPE="${options[$((gpu_choice-1))]}"
            return
        fi
        warn "Invalid choice. Please enter 1-${#options[@]}."
    done
}

present_gpu_options() {
    echo ""
    info "GPU Detection:"

    if [[ ${#DETECTED_GPUS[@]} -eq 0 ]]; then
        warn "No GPUs detected - will use auto-detection at boot"
        DETECTED_GPU_TYPE="auto"
        return
    fi

    classify_detected_gpus
    echo ""

    if [[ $GPU_TYPE_COUNT -gt 1 ]]; then
        select_primary_gpu
    else
        # Single GPU type - auto-select from the first (only) entry
        DETECTED_GPU_TYPE="${GPU_TYPES_IN_ORDER[0]%%:*}"
    fi

    success "GPU type: $DETECTED_GPU_TYPE"
}

present_display_options() {
    echo ""

    if [[ ${#DETECTED_OUTPUTS[@]} -eq 0 ]]; then
        info "No display outputs detected yet (normal before first boot)"
        DETECTED_DRM_PATH="auto"
        return
    fi

    if [[ ${#DETECTED_OUTPUTS[@]} -eq 1 ]]; then
        DETECTED_DRM_PATH="${DETECTED_OUTPUTS[0]}"
        info "Display output: $DETECTED_DRM_PATH"
        return
    fi

    echo "  Multiple display outputs detected:"
    echo ""
    local i=1
    for output in "${DETECTED_OUTPUTS[@]}"; do
        # Extract just the card-OUTPUT part for readability
        local short_name="${output##*/+drm:}"
        echo "    $i) $short_name"
        ((i++))
    done
    echo "    $i) Auto-detect at boot (recommended)"
    echo ""

    while true; do
        echo -n "  Choose primary display [1-$i, blank=auto]: "
        read -r display_choice || { warn "Input cancelled"; return 1; }

        if [[ "$display_choice" == "$i" ]] || [[ -z "$display_choice" ]]; then
            DETECTED_DRM_PATH="auto"
            info "Using auto-detection at boot"
            break
        elif [[ "$display_choice" =~ ^[0-9]+$ ]] && [[ "$display_choice" -ge 1 ]] && [[ "$display_choice" -lt $i ]]; then
            DETECTED_DRM_PATH="${DETECTED_OUTPUTS[$((display_choice-1))]}"
            break
        fi
        warn "Invalid choice. Please enter 1-$i."
    done

    success "DRM path: $DETECTED_DRM_PATH"
}

present_config_info() {
    echo ""
    info "Hyprland config: $HYPR_CONFIG_DIR"

    if [[ ${#DETECTED_EXECS_FILES[@]} -eq 0 ]]; then
        warn "No execs.conf files found"
    else
        echo "  Detected exec configs:"
        for file in "${DETECTED_EXECS_FILES[@]}"; do
            local rel_path="${file#"$HOME"/}"
            echo "    • ~/$rel_path"
        done
    fi

    # Show hyprlock running status (informational)
    if is_hyprlock_running; then
        info "hyprlock is currently running"
    fi

    # Show if hyprlock already configured in any files
    if [[ ${#HYPRLOCK_CONFIGURED_FILES[@]} -gt 0 ]]; then
        echo ""
        warn "hyprlock already configured in:"
        for file in "${HYPRLOCK_CONFIGURED_FILES[@]}"; do
            local rel_path="${file#"$HOME"/}"
            echo "    • ~/$rel_path"
        done
    fi
}

# Check if UWSM is active (for auto-detection helper)
# Uses timeout to prevent hanging if systemd is unresponsive
check_uwsm_status() {
    local status
    status=$(systemctl_safe --user --timeout="$SYSTEMCTL_VERIFY_TIMEOUT" is-active uwsm-app@Hyprland.service 2>&1) || status="timeout"

    case "$status" in
        active)
            echo "active"
            ;;
        inactive)
            echo "inactive"
            ;;
        failed)
            # Distinguish failed from not-found - failed means UWSM IS configured but broken
            echo "failed"
            ;;
        *)
            # "unknown", "could not be found", timeout, etc.
            echo "not-found"
            ;;
    esac
}

# Manual session method selection menu
# Sets: SESSION_METHOD to "exec-once" or "uwsm"
select_session_method_manual() {
    echo ""
    echo "  ─────────────────────────────────────────────────────────────────"
    echo -e "  ${BOLD}Manual Selection${NC}"
    echo "  ─────────────────────────────────────────────────────────────────"
    echo ""
    echo -e "  ${CYAN}UWSM${NC}: Hyprland runs via systemd (uwsm start hyprland)"
    echo -e "  ${CYAN}exec-once${NC}: Hyprland starts from TTY/shell config"
    echo ""
    echo "    1) Direct/TTY autologin (exec-once method)"
    echo "    2) UWSM managed session (systemd service method)"
    echo ""

    while true; do
        echo -n "  Choose [1-2]: "
        read -r method_choice || { warn "Input cancelled"; return 1; }

        case "$method_choice" in
            1)
                SESSION_METHOD="exec-once"
                success "Session method: exec-once (hyprlock added to Hyprland config)"
                return 0
                ;;
            2)
                SESSION_METHOD="uwsm"
                success "Session method: UWSM (hyprlock as systemd service)"
                return 0
                ;;
            *)
                warn "Invalid choice. Please enter 1 or 2."
                ;;
        esac
    done
}

# Try to auto-detect and confirm session method with user
# Returns: 0 if SESSION_METHOD set, 1 if manual selection needed
# Sets: SESSION_METHOD to "exec-once" or "uwsm" on success
try_auto_detect_session_method() {
    info "Detecting session method..."
    local uwsm_status
    uwsm_status=$(check_uwsm_status)

    case "$uwsm_status" in
        active)
            echo ""
            echo -e "  ${GREEN}Detected: UWSM is active${NC}"
            echo "  Hyprland is running as a systemd user service."
            echo ""
            if ask_yes "Use UWSM method? (hyprlock as systemd service)"; then
                SESSION_METHOD="uwsm"
                success "Session method: uwsm"
                return 0
            fi
            return 1  # User declined, needs manual selection
            ;;
        inactive|not-found)
            echo ""
            if [[ "$uwsm_status" == "inactive" ]]; then
                echo -e "  ${CYAN}Detected: UWSM service exists but is inactive${NC}"
            else
                echo -e "  ${CYAN}Detected: UWSM not installed or not configured${NC}"
            fi
            echo "  Hyprland appears to start from your shell/TTY."
            echo ""
            if ask_yes "Use exec-once method? (hyprlock in Hyprland config)"; then
                SESSION_METHOD="exec-once"
                success "Session method: exec-once"
                return 0
            fi
            return 1  # User declined, needs manual selection
            ;;
        failed)
            echo ""
            echo -e "  ${YELLOW}Detected: UWSM service is in failed state${NC}"
            echo "  Cannot reliably auto-detect. Please choose manually."
            echo ""
            return 1  # Cannot auto-detect, needs manual selection
            ;;
    esac
    return 1  # Fallback
}

# Present session method selection (UWSM vs exec-once)
# Auto-detects first, falls back to manual selection if ambiguous
# Sets: SESSION_METHOD to "exec-once" or "uwsm"
present_session_method() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo -e "  ${BOLD}SESSION METHOD DETECTION${NC}"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    # Try auto-detection first, fall back to manual if declined or failed
    if try_auto_detect_session_method; then
        return 0
    fi

    select_session_method_manual
}

present_detection_summary() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo -e "  ${BOLD}SYSTEM DETECTION SUMMARY${NC}"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "  Username:       $DETECTED_USERNAME"
    echo "  GPU type:       $DETECTED_GPU_TYPE"
    echo "  DRM path:       $DETECTED_DRM_PATH"
    echo "  Config dir:     $HYPR_CONFIG_DIR"
    echo "  Session method: $SESSION_METHOD"
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    if ! ask_yes "Proceed with these settings?"; then
        info "Installation cancelled"
        exit 0
    fi
}

# ============================================================================
# SECTION 13: Installation Functions
# ============================================================================

# Apply a single GPU environment variable by uncommenting it in the launcher script
# Args: $1 = temp file, $2 = variable name, $3 = value
# Returns: 0 on success, 1 on sed failure or if pattern wasn't found/applied
apply_gpu_variable() {
    local temp_file="$1"
    local var_name="$2"
    local var_value="$3"
    local pattern="# set -gx $var_name $var_value"
    local replacement="set -gx $var_name $var_value"

    # Check if pattern exists before attempting substitution
    if ! grep -q "^$pattern$" "$temp_file" 2>/dev/null; then
        error "GPU setting not found in launcher: $var_name"
        echo "  Expected pattern: $pattern"
        echo "  This may indicate a launcher script version mismatch"
        return 1
    fi

    # Apply the substitution
    if ! sed -i "s/^$pattern$/$replacement/" "$temp_file"; then
        error "Failed to apply GPU setting: $var_name"
        return 1
    fi

    # Verify substitution was applied (pattern should be gone)
    if grep -q "^$pattern$" "$temp_file" 2>/dev/null; then
        error "GPU setting was not applied (pattern still present): $var_name"
        return 1
    fi

    return 0
}

# Apply GPU-specific environment variables to launcher script
# Args: $1 = temp file path
apply_gpu_env_config() {
    local temp_file="$1"

    case "$DETECTED_GPU_TYPE" in
        nvidia)
            info "Configuring NVIDIA GPU settings..."
            apply_gpu_variable "$temp_file" "LIBVA_DRIVER_NAME" "nvidia" || return 1
            apply_gpu_variable "$temp_file" "__GLX_VENDOR_LIBRARY_NAME" "nvidia" || return 1
            apply_gpu_variable "$temp_file" "NVD_BACKEND" "direct" || return 1
            ;;
        amd)
            info "Configuring AMD GPU settings..."
            apply_gpu_variable "$temp_file" "LIBVA_DRIVER_NAME" "radeonsi" || return 1
            ;;
        intel)
            info "Configuring Intel GPU settings..."
            apply_gpu_variable "$temp_file" "LIBVA_DRIVER_NAME" "iHD" || return 1
            ;;
        auto|*)
            info "GPU type 'auto' - leaving configuration for runtime detection"
            ;;
    esac
}

# Apply DRM path configuration to launcher script
# Args: $1 = temp file path
apply_drm_path_config() {
    local temp_file="$1"

    [[ "$DETECTED_DRM_PATH" == "auto" ]] && return 0

    # Validate DRM path format strictly (security: prevent sed injection)
    # Expected format: /run/udev/data/+drm:card0-HDMI-A-1
    # Allowed characters: alphanumeric, /, +, :, -, _
    if [[ ! "$DETECTED_DRM_PATH" =~ ^/run/udev/data/\+drm:card[0-9]+-[A-Za-z0-9_-]+$ ]]; then
        error "DRM path doesn't match expected format: $DETECTED_DRM_PATH"
        echo "  Expected format: /run/udev/data/+drm:cardN-OUTPUT-NAME"
        echo "  Example: /run/udev/data/+drm:card0-HDMI-A-1"
        return 1
    fi

    info "Setting DRM path: $DETECTED_DRM_PATH"
    # Escape path for sed - handle all special characters
    # Order matters: backslashes first, then other special chars
    local escaped_drm_path="${DETECTED_DRM_PATH//\\/\\\\}"  # \ -> \\
    escaped_drm_path="${escaped_drm_path//&/\\&}"            # & -> \&
    escaped_drm_path="${escaped_drm_path//\//\\/}"           # / -> \/
    escaped_drm_path="${escaped_drm_path//\$/\\$}"           # $ -> \$

    # Add HYPR_DRM_PATH after the shebang
    sed -i "2i\\
# DRM path set by installer\\
set -gx HYPR_DRM_PATH \"$escaped_drm_path\"\\
" "$temp_file" || { error "Failed to set DRM path"; return 1; }
}

# Configuration function for launcher script (applies GPU and DRM settings)
# Called by install_file_atomically via INSTALL_CONFIG_FUNC
configure_launcher_script() {
    local temp_file="$1"
    apply_gpu_env_config "$temp_file" || return 1
    apply_drm_path_config "$temp_file" || return 1
}

install_launcher_script() {
    INSTALL_CONFIG_FUNC="configure_launcher_script"
    install_file_atomically "$LAUNCHER_SRC" "$LAUNCHER_DEST" 755 "launcher script"
    local result=$?
    INSTALL_CONFIG_FUNC=""
    return $result
}

install_fish_hook() {
    # No config function needed for fish hook - just straight copy
    INSTALL_CONFIG_FUNC=""
    install_file_atomically "$FISH_HOOK_SRC" "$FISH_HOOK_DEST" 644 "fish hook"
}

# Install hyprlock as a systemd user service (for UWSM method)
install_hyprlock_service() {
    local dest_dir
    dest_dir="$(dirname "$HYPRLOCK_SERVICE_DEST")"

    if dry_run_preview "Would create: $HYPRLOCK_SERVICE_DEST"; then
        dry_run_preview "Would run: systemctl --user daemon-reload"
        dry_run_preview "Would run: systemctl --user enable hyprlock.service"
        return 0
    fi

    # Check source file exists
    if [[ ! -f "$HYPRLOCK_SERVICE_SRC" ]]; then
        error "Source file not found: $HYPRLOCK_SERVICE_SRC"
        return 1
    fi

    mkdir -p "$dest_dir" || { error "Failed to create directory: $dest_dir"; return 1; }
    cp "$HYPRLOCK_SERVICE_SRC" "$HYPRLOCK_SERVICE_DEST" || { error "Failed to copy hyprlock service"; return 1; }

    # Ensure file is readable by systemd (user-readable)
    chmod 644 "$HYPRLOCK_SERVICE_DEST" || { error "Failed to set permissions on service file"; return 1; }

    # Verify file is readable before proceeding
    if [[ ! -r "$HYPRLOCK_SERVICE_DEST" ]]; then
        error "Service file not readable: $HYPRLOCK_SERVICE_DEST"
        return 1
    fi

    # Reload and enable (with timeouts to prevent hang)
    systemctl_safe --user daemon-reload || { error "Failed to reload user systemd (timeout)"; return 1; }

    # Verify service is loadable before enabling
    if ! systemctl_safe --user --timeout="$SYSTEMCTL_VERIFY_TIMEOUT" --quiet cat hyprlock.service; then
        error "Systemd cannot load hyprlock.service - check file format"
        return 1
    fi

    systemctl_safe --user enable hyprlock.service || { error "Failed to enable hyprlock service (timeout)"; return 1; }

    success "Hyprlock service installed and enabled: $HYPRLOCK_SERVICE_DEST"
}

# Remove hyprlock systemd service (for uninstall)
remove_hyprlock_service() {
    if [[ ! -f "$HYPRLOCK_SERVICE_DEST" ]]; then
        return 0
    fi

    if dry_run_preview "Would disable and remove: $HYPRLOCK_SERVICE_DEST"; then
        return 0
    fi

    # Disable first, then remove (with timeouts)
    systemctl_safe --user --quiet disable hyprlock.service || true
    rm -f "$HYPRLOCK_SERVICE_DEST" || { warn "Could not remove service file"; }
    systemctl_safe --user daemon-reload || { warn "Failed to reload user systemd"; }

    success "Removed hyprlock systemd service"
}

# Show UWSM service confirmation (when using systemd service method)
present_uwsm_service_configured() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo -e "  ${GREEN}${BOLD}[OK] HYPRLOCK SERVICE CONFIGURED${NC}"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "  The hyprlock systemd service has been installed and enabled."
    echo "  It will start automatically when your graphical session begins."
    echo ""
    echo -e "  ${CYAN}Service location:${NC} $HYPRLOCK_SERVICE_DEST"
    echo ""
    echo "  To check status:  systemctl --user status hyprlock.service"
    echo "  To disable:       systemctl --user disable hyprlock.service"
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    read -r -p "Press Enter to continue..."
}

# Warn about hybrid configuration (exec-once + UWSM service both present)
# Returns: 0 to continue, 1 to skip configuration
check_hybrid_configuration() {
    is_hyprlock_service_installed || return 0

    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo -e "  ${RED}${BOLD}[!] HYBRID CONFIGURATION DETECTED${NC}"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "  A hyprlock systemd service is already installed (UWSM method)."
    echo "  Adding exec-once = hyprlock would create a HYBRID configuration"
    echo "  where hyprlock starts TWICE - this will cause problems!"
    echo ""
    echo "  How would you like to proceed?"
    echo ""
    echo "    1) Remove the service now and continue with exec-once method"
    echo "    2) Skip hyprlock config (keep existing UWSM service)"
    echo "    3) Continue anyway (NOT RECOMMENDED - will cause conflicts)"
    echo ""
    local choice
    read -r -p "  Enter choice [1-3]: " choice

    case "$choice" in
        1)
            info "Removing hyprlock systemd service..."
            # Use --quiet flag instead of 2>/dev/null to preserve timeout visibility
            if systemctl_safe --user --quiet disable hyprlock.service; then
                success "hyprlock.service disabled"
            else
                warn "Could not disable hyprlock.service (may not be enabled, or timeout)"
            fi
            if systemctl_safe --user --quiet stop hyprlock.service; then
                success "hyprlock.service stopped"
            else
                info "hyprlock.service not running (already stopped)"
            fi
            return 0  # Continue with exec-once configuration
            ;;
        2)
            info "Skipping hyprlock configuration - keeping existing UWSM service"
            echo ""
            read -r -p "Press Enter to continue..."
            return 1  # Skip configuration
            ;;
        3)
            warn "Proceeding with hybrid configuration - you may experience issues"
            return 0
            ;;
        *)
            info "Invalid choice - skipping hyprlock configuration for safety"
            return 1
            ;;
    esac
}

# Check if hyprlock is already configured in execs files
# Returns: 0 to continue, 1 to skip configuration
check_existing_hyprlock_config() {
    [[ ${#HYPRLOCK_CONFIGURED_FILES[@]} -gt 0 ]] || return 0

    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo -e "  ${YELLOW}${BOLD}[!] HYPRLOCK ALREADY CONFIGURED${NC}"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "  Found existing hyprlock configuration in:"
    for file in "${HYPRLOCK_CONFIGURED_FILES[@]}"; do
        local rel_path="${file#"$HOME"/}"
        echo "      • ~/$rel_path"
    done
    echo ""

    if ! ask "Add hyprlock to config anyway? (creates duplicate)"; then
        success "Skipping hyprlock configuration (already present)"
        echo ""
        read -r -p "Press Enter to continue..."
        return 1
    fi
    warn "Proceeding - you may have duplicate hyprlock entries"
    return 0
}

# Show manual exec-once instructions and offer editor
present_execonce_manual_instructions() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo -e "  ${BOLD}MANUAL STEP REQUIRED: Add hyprlock to your config${NC}"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo -e "  Add this line to the ${BOLD}TOP${NC} of your Hyprland execs config:"
    echo "  (Must be the FIRST exec-once, with NO delay)"
    echo ""
    echo -e "      ${GREEN}exec-once = hyprlock${NC}"
    echo ""

    if [[ ${#DETECTED_EXECS_FILES[@]} -gt 0 ]]; then
        echo "  Your exec config files:"
        for file in "${DETECTED_EXECS_FILES[@]}"; do
            local rel_path="${file#"$HOME"/}"
            echo "      • ~/$rel_path"
        done
        echo ""
        echo -e "  Choose one that is ${BOLD}NOT${NC} overwritten by dotfile updates"
        echo "  (usually in custom.d/ or similar)"
    fi

    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    # Offer to open config in editor if one is available
    if find_editor && ask "Open your config in editor ($FOUND_EDITOR)?"; then
        if [[ ${#DETECTED_EXECS_FILES[@]} -eq 1 ]]; then
            "$FOUND_EDITOR" "${DETECTED_EXECS_FILES[0]}" || warn "Editor exited with error"
        elif [[ ${#DETECTED_EXECS_FILES[@]} -gt 1 ]]; then
            echo ""
            echo "  Which file to edit?"
            local selected_file
            if selected_file=$(select_from_menu "Choose" "${DETECTED_EXECS_FILES[@]}"); then
                "$FOUND_EDITOR" "$selected_file" || warn "Editor exited with error"
            fi
        fi
    fi

    echo ""
    read -r -p "Press Enter when you've added the line..."
}

# Show instructions for hyprlock setup based on session method
# For exec-once: Guide user to add exec-once = hyprlock to config
# For UWSM: Service is already installed, just confirm
present_execs_instructions() {
    # UWSM method: Service is already enabled, no manual config needed
    if [[ "$SESSION_METHOD" == "uwsm" ]]; then
        present_uwsm_service_configured
        return
    fi

    # exec-once method: Guide user to add line to config
    # Check for hybrid configuration and existing config, then show instructions
    check_hybrid_configuration || return
    check_existing_hyprlock_config || return
    present_execonce_manual_instructions
}

# ============================================================================
# SECTION 14: System-Level Installation (Sudo)
# ============================================================================

request_sudo() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo -e "  ${BOLD}SYSTEM-LEVEL CONFIGURATION${NC} (requires sudo)"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "  The following requires administrator privileges:"
    echo "    • Create autologin override for getty@tty1"
    echo "    • Reload systemd daemon"
    echo ""

    # Use ask() (defaults to No) - system modification requires explicit opt-in
    if ! ask "Proceed with sudo operations?"; then
        warn "Skipping system-level configuration"
        echo ""
        echo "  You'll need to manually create: $SYSTEMD_OVERRIDE_DEST"
        echo "  And run: sudo systemctl daemon-reload"
        return 1
    fi

    # Test sudo access (with timeout to prevent hang)
    if ! timeout "$SUDO_AUTH_TIMEOUT" sudo -v; then
        error "Failed to get sudo access"
        return 1
    fi

    return 0
}

create_autologin_override() {
    if dry_run_preview "Would create: $SYSTEMD_OVERRIDE_DEST"; then
        return 0
    fi

    sudo mkdir -p "$SYSTEMD_OVERRIDE_DIR" || { error "Failed to create systemd override directory"; return 1; }

    # Backup existing override file before modification (critical - don't proceed without backup)
    if [[ -f "$SYSTEMD_OVERRIDE_DEST" ]]; then
        local backup_file
        backup_file="${SYSTEMD_OVERRIDE_DEST}.backup.$(date +%Y%m%d_%H%M%S_%N)" || {
            error "Failed to generate backup timestamp"
            return 1
        }
        if ! sudo cp -p "$SYSTEMD_OVERRIDE_DEST" "$backup_file"; then
            error "Failed to backup existing systemd override - cannot proceed"
            echo "  Refusing to overwrite $SYSTEMD_OVERRIDE_DEST without backup"
            return 1
        fi
        info "Backed up existing config to: $backup_file"
    fi

    # Re-validate username immediately before use (defense in depth)
    if ! id "$DETECTED_USERNAME" &>/dev/null; then
        error "Username no longer valid: $DETECTED_USERNAME"
        return 1
    fi

    # Security: Block usernames with newlines/carriage returns (could inject systemd directives)
    if [[ "$DETECTED_USERNAME" == *$'\n'* ]] || [[ "$DETECTED_USERNAME" == *$'\r'* ]]; then
        error "Username contains invalid control characters"
        return 1
    fi

    cat << EOF | sudo tee "$SYSTEMD_OVERRIDE_DEST" > /dev/null || { error "Failed to write autologin config"; return 1; }
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty -o "-p -f -- \\u" --noclear --autologin "$DETECTED_USERNAME" %I \$TERM
EOF

    # Use timeout to prevent hang if systemd is unresponsive
    systemctl_safe --sudo daemon-reload || { error "Failed to reload systemd daemon (timeout)"; return 1; }

    # Validate the systemd config can be parsed (catches syntax errors early)
    if ! systemctl_safe --sudo --timeout="$SYSTEMCTL_VERIFY_TIMEOUT" --quiet cat getty@tty1.service; then
        warn "Systemd may have issues parsing getty@tty1 config - check manually"
    fi

    success "Autologin configured for: $DETECTED_USERNAME"
}

# ============================================================================
# SECTION 15: Staged Testing
# ============================================================================

setup_tty2_testing() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo -e "  ${BOLD}STAGED TESTING${NC} (Mandatory before SDDM cutover)"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "  Before disabling SDDM, you MUST test on tty2 to verify"
    echo "  everything works correctly."
    echo ""

    if $DRY_RUN; then
        echo "$(dry_run_prefix)Would start getty@tty2"
        return 0
    fi

    info "Starting getty on tty2..."
    if systemctl_safe --sudo --quiet start getty@tty2; then
        success "getty@tty2 started"
    elif systemctl_safe --quiet is-active getty@tty2; then
        info "getty@tty2 already running"
    else
        echo ""
        error "Could not start getty@tty2"
        echo ""
        echo "  This is required for staged testing. Possible causes:"
        echo "    • systemd issue (try: sudo systemctl status getty@tty2)"
        echo "    • Permission issue with sudo"
        echo "    • getty@tty2 is masked or disabled"
        echo ""
        echo "  Manual fix: sudo systemctl start getty@tty2"
        echo ""
        if ask "Try to continue anyway? (You can start getty manually)"; then
            warn "Continuing without getty@tty2 auto-start"
            echo ""
            echo "  To start getty manually, run in another terminal:"
            echo -e "    ${CYAN}sudo systemctl start getty@tty2${NC}"
            echo ""
            echo "  Then switch to tty2 (Ctrl+Alt+F2) to verify you see a login prompt."
            echo ""
            read -r -p "Press Enter when getty@tty2 is ready..."

            # Verify getty is now running before proceeding
            if ! systemctl_safe --quiet is-active getty@tty2; then
                warn "getty@tty2 still not running - testing may fail"
                if ! ask "Proceed anyway?"; then
                    return 1
                fi
            else
                success "getty@tty2 is now running"
            fi
            return 0
        else
            info "Aborting - please fix getty@tty2 and re-run installer"
            return 1
        fi
    fi
}

guide_tty2_test() {
    echo ""
    echo -e "  ${BOLD}Test procedure:${NC}"
    echo ""
    echo -e "    1. Press ${CYAN}Ctrl+Alt+F2${NC} to switch to tty2"
    echo "    2. Login with your password"
    echo "    3. Verify Hyprland starts automatically"
    echo "    4. Verify hyprlock appears immediately"
    echo "    5. Unlock with your password"
    echo "    6. Verify desktop appears correctly"
    echo -e "    7. Press ${CYAN}Ctrl+Alt+F1${NC} to return here"
    echo ""
    echo -e "  ${GREEN}SUCCESS indicators:${NC}"
    echo "    ✓ tty2 login prompt appears within ~5 seconds"
    echo "    ✓ After login, you see 'Starting Hyprland...' message"
    echo "    ✓ hyprlock screen appears (may take 3-5 seconds on first boot)"
    echo "    ✓ Your password unlocks hyprlock"
    echo "    ✓ Hyprland desktop renders correctly"
    echo ""
    echo -e "  ${RED}FAILURE indicators:${NC}"
    echo "    ✗ No tty2 login prompt → getty failed to start"
    echo "    ✗ Login succeeds but black screen → GPU initialization failed"
    echo "    ✗ hyprlock appears but won't unlock → hyprlock config issue"
    echo "    ✗ Screen flickers/crashes → check ~/.hyprland.log"
    echo ""
    echo -e "  ${YELLOW}If the test FAILS:${NC}"
    echo "    • Press Ctrl+C during the 10-second restart delay"
    echo "    • Check ~/.hyprland.log for errors"
    echo "    • Return here (Ctrl+Alt+F1) to troubleshoot"
    echo ""

    read -r -p "Press Enter when ready to test (then switch to tty2)..."
}

# Handle troubleshooting menu when test fails
# Returns: 0 to continue testing, 1 to exit installer
handle_test_troubleshooting() {
    echo ""
    echo "  Troubleshooting options:"
    echo "    1) View ~/.hyprland.log"
    echo "    2) Edit launcher script"
    echo "    3) Try test again"
    echo "    4) Exit installer (SDDM not modified)"
    echo ""
    echo -n "  Choose [1-4]: "
    read -r trouble_choice

    case "$trouble_choice" in
        1)
            echo ""
            echo "=== Last 50 lines of ~/.hyprland.log ==="
            tail -50 ~/.hyprland.log 2>/dev/null || echo "(Log file not found)"
            echo ""
            read -r -p "Press Enter to continue..."
            ;;
        2)
            if find_editor; then
                "$FOUND_EDITOR" "$LAUNCHER_DEST" || warn "Editor exited with error"
                echo ""
                echo "  Changes saved. You'll need to test again on tty2 to verify the fix."
                echo "  Note: If Hyprland is running on tty2, logout first to apply changes."
                echo ""
                read -r -p "Press Enter when ready to test again..."
                guide_tty2_test
            else
                warn "No editor found (tried: \$EDITOR, nano, vim, nvim, vi)"
                echo "  Edit manually: $LAUNCHER_DEST"
                read -r -p "Press Enter to continue..."
            fi
            ;;
        3)
            guide_tty2_test
            ;;
        4)
            info "Exiting - SDDM not modified"
            echo ""
            echo "  User-level components are installed."
            echo "  Fix issues and re-run installer when ready."
            return 1
            ;;
        *)
            warn "Invalid choice. Please enter 1-4."
            ;;
    esac
    return 0
}

confirm_test_passed() {
    echo ""

    if $SKIP_TEST; then
        warn "Staged testing SKIPPED (--skip-test flag)"
        echo ""
        if ! ask "Are you SURE you want to proceed without testing?"; then
            exit 1
        fi
        return 0
    fi

    local test_attempts=0
    local max_attempts=5

    while true; do
        if ask "Did the tty2 test SUCCEED? (Hyprland started, hyprlock appeared)"; then
            success "Test passed! Ready for SDDM cutover"
            return 0
        fi

        ((test_attempts++))
        if ((test_attempts >= max_attempts)); then
            echo ""
            error "Test unsuccessful after multiple attempts"
            echo ""
            echo "  The tty2 test didn't pass. This usually means:"
            echo "    • Hyprland config issue (check ~/.hyprland.log)"
            echo "    • GPU environment variables need adjustment"
            echo "    • hyprlock not configured correctly"
            echo ""
            echo "  User-level components are installed."
            echo "  Fix the underlying issue and re-run the installer."
            exit 1
        fi

        warn "Test did not pass"
        if ! handle_test_troubleshooting; then
            exit 0  # User chose to exit
        fi
    done
}

# ============================================================================
# SECTION 16: SDDM Cutover
# ============================================================================

confirm_sddm_disable() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo -e "  ${RED}${BOLD}⚠️  CRITICAL STEP: DISABLE SDDM${NC}"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "  You are about to disable the SDDM display manager."
    echo ""
    echo "  This means:"
    echo "    • No graphical login screen on boot"
    echo "    • Boot goes directly: TTY → Hyprland → hyprlock"
    echo "    • If something breaks, you need TTY or Live USB to recover"
    echo ""
    echo -e "  ${YELLOW}Recovery commands (memorize these!):${NC}"
    echo -e "    From tty3:   ${CYAN}sudo systemctl enable sddm && sudo reboot${NC}"
    echo -e "    From USB:    ${CYAN}arch-chroot /mnt systemctl enable sddm${NC}"
    echo ""

    if ! ask_critical "Disable SDDM now?" "yes"; then
        info "SDDM cutover cancelled"
        echo ""
        echo "  User-level components are installed."
        echo "  Re-run installer when ready to disable SDDM."
        exit 0
    fi
}

disable_sddm() {
    if dry_run_preview "Would run: sudo systemctl disable sddm"; then
        return 0
    fi

    if is_sddm_enabled; then
        systemctl_safe --sudo disable sddm || { error "Failed to disable SDDM (timeout)"; return 1; }
        success "SDDM disabled"
    else
        info "SDDM was already disabled"
    fi
}

present_final_instructions() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo -e "  ${GREEN}${BOLD}✓ INSTALLATION COMPLETE${NC}"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "  On next reboot:"
    echo "    1. TTY autologin (no password prompt)"
    echo "    2. Hyprland starts automatically"
    echo "    3. hyprlock appears as login screen"
    echo "    4. Enter password to unlock → Desktop"
    echo ""
    echo -e "  ${YELLOW}Recovery commands:${NC}"
    echo -e "    Quick rollback: ${CYAN}sudo systemctl enable sddm && sudo reboot${NC}"
    echo -e "    From Live USB:  ${CYAN}arch-chroot /mnt systemctl enable sddm${NC}"
    echo ""
    echo -e "  ${YELLOW}Files installed:${NC}"
    echo "    • $LAUNCHER_DEST"
    echo "    • $FISH_HOOK_DEST"
    echo "    • $SYSTEMD_OVERRIDE_DEST"
    echo ""

    if ask "Reboot now?"; then
        # Use systemctl reboot (cleaner than timeout+reboot, better error messages)
        sudo systemctl reboot || {
            error "Reboot command failed"
            echo "  Run manually: sudo systemctl reboot"
        }
    else
        info "Remember to reboot to apply changes"
    fi
}

# ============================================================================
# SECTION 17: Uninstall Functions
# ============================================================================

# Remove user-level components (launcher, fish hook, service, config, backups)
# Args: $1 = was_uwsm (true/false)
uninstall_user_components() {
    local was_uwsm="$1"

    remove_if_exists "$LAUNCHER_DEST" "Launcher script"
    remove_if_exists "$FISH_HOOK_DEST" "Fish hook"

    # Remove hyprlock systemd service (if installed for UWSM)
    if $was_uwsm || is_hyprlock_service_installed; then
        remove_hyprlock_service
    fi

    # Remove config file
    remove_if_exists "$CONFIG_FILE" "Installation config"

    # Clean up backup files created during installation/updates
    local backup_count=0
    local -a backup_dirs=("$LAUNCHER_DEST" "$FISH_HOOK_DEST" "$HYPRLOCK_SERVICE_DEST")

    for dir in "${backup_dirs[@]}"; do
        local parent_dir
        parent_dir="$(dirname "$dir")"
        if [[ -d "$parent_dir" ]]; then
            while IFS= read -r -d '' bak_file; do
                if $DRY_RUN; then
                    echo "$(dry_run_prefix)Would remove backup: $bak_file"
                else
                    rm -f "$bak_file" && ((backup_count++))
                fi
            done < <(find "$parent_dir" -maxdepth 1 -name "*.backup.*" -type f -print0 2>/dev/null)
        fi
    done

    if [[ $backup_count -gt 0 ]]; then
        success "Cleaned up $backup_count backup file(s)"
    fi
}

# Remove systemd autologin override (requires sudo)
uninstall_system_component() {
    [[ -f "$SYSTEMD_OVERRIDE_DEST" ]] || return 0

    # Use ask() (default No) - destructive operation requires explicit opt-in
    if ! ask "Remove systemd autologin override? (requires sudo)"; then
        return 0
    fi

    if $DRY_RUN; then
        echo "$(dry_run_prefix)Would remove: $SYSTEMD_OVERRIDE_DEST"
    else
        sudo rm -f "$SYSTEMD_OVERRIDE_DEST" || warn "Could not remove systemd override"
        systemctl_safe --sudo daemon-reload || warn "Systemd reload timed out"
        success "Removed systemd override"
    fi
}

# Phase 1: Detect installation method for uninstall
# Sets: UNINSTALL_WAS_UWSM (true/false)
UNINSTALL_WAS_UWSM=false
uninstall_detect_method() {
    UNINSTALL_WAS_UWSM=false
    if load_install_config && [[ "$SESSION_METHOD" == "uwsm" ]]; then
        UNINSTALL_WAS_UWSM=true
        info "Detected UWSM installation"
    elif is_hyprlock_service_installed; then
        UNINSTALL_WAS_UWSM=true
        info "Detected hyprlock systemd service"
    fi
}

# Phase 2: Show manual cleanup steps after uninstall
uninstall_show_manual_steps() {
    echo ""
    echo -e "  ${YELLOW}Remaining manual steps:${NC}"
    if $UNINSTALL_WAS_UWSM; then
        echo "    1. (UWSM method) No manual hyprlock config changes needed"
    else
        echo "    1. Remove 'exec-once = hyprlock' from your execs.conf"
    fi
    echo -e "    2. Re-enable SDDM: ${CYAN}sudo systemctl enable sddm${NC}"
    echo "    3. Reboot"
    echo ""
}

# Phase 3: Offer to re-enable SDDM
uninstall_restore_sddm() {
    if ask_yes "Enable SDDM now?"; then
        if $DRY_RUN; then
            echo "$(dry_run_prefix)Would run: sudo systemctl enable sddm"
        else
            systemctl_safe --sudo enable sddm || { error "Failed to enable SDDM (timeout)"; }
            success "SDDM re-enabled"
        fi
    fi
}

# Phase 4: Offer reboot
uninstall_maybe_reboot() {
    echo ""
    success "Uninstall complete"

    if ask "Reboot now?"; then
        # Use systemctl reboot (cleaner than timeout+reboot, better error messages)
        sudo systemctl reboot || {
            error "Reboot command failed"
            echo "  Run manually: sudo systemctl reboot"
        }
    fi
}

# Main uninstall orchestrator
uninstall() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo -e "  ${BOLD}UNINSTALL hypr-login${NC}"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    uninstall_detect_method

    # Use ask() which defaults to No - prevents accidental uninstall from Enter key
    # (cat-proof safety: destructive operations should require explicit 'y')
    if ! ask "Remove all hypr-login components?"; then
        info "Uninstall cancelled"
        exit 0
    fi

    echo ""
    uninstall_user_components "$UNINSTALL_WAS_UWSM"
    uninstall_system_component

    uninstall_show_manual_steps
    uninstall_restore_sddm
    uninstall_maybe_reboot
}

# ============================================================================
# SECTION 18: Update Mode
# ============================================================================

# Update hyprlock service if needed (UWSM method)
update_hyprlock_service() {
    # Skip if not using UWSM and no service installed
    [[ "$SESSION_METHOD" != "uwsm" ]] && ! is_hyprlock_service_installed && return 0

    if is_hyprlock_service_installed; then
        info "Updating hyprlock systemd service..."
        backup_file "$HYPRLOCK_SERVICE_DEST"
        install_hyprlock_service || { error "Failed to update hyprlock service"; return 1; }
    elif [[ "$SESSION_METHOD" == "uwsm" ]]; then
        info "Installing hyprlock systemd service (UWSM method)..."
        install_hyprlock_service || { error "Failed to install hyprlock service"; return 1; }
    fi
}

# Verify/repair systemd configuration
update_systemd_config() {
    if ! is_systemd_configured; then
        warn "Systemd autologin override missing"
        if ask_yes "Reconfigure systemd autologin?"; then
            detect_username
            if request_sudo; then
                create_autologin_override
            fi
        fi
    else
        success "Systemd configuration intact"
    fi
}

update() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo -e "  ${BOLD}UPDATE hypr-login${NC}"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    # Redirect to full install if not installed
    if ! is_launcher_installed && ! is_fish_hook_installed; then
        warn "hypr-login not installed. Running full installation..."
        install
        return
    fi

    # Load saved configuration from previous install
    if load_install_config; then
        info "Loaded previous configuration (session method: ${SESSION_METHOD:-unknown})"
    else
        info "No saved configuration found"
    fi

    validate_source_files

    # Backup existing launcher
    is_launcher_installed && backup_file "$LAUNCHER_DEST"

    # Re-run detection for GPU settings
    detect_gpus
    present_gpu_options

    # Install updated files
    install_launcher_script || { error "Failed to update launcher script"; return 1; }
    install_fish_hook || { error "Failed to update fish hook"; return 1; }

    # Update UWSM service if applicable
    update_hyprlock_service || { error "Failed to update hyprlock service"; return 1; }

    # Verify systemd configuration
    update_systemd_config || { error "Failed to verify systemd config"; return 1; }

    echo ""
    success "Update complete"
    info "Restart your shell or reboot to apply changes"
}

# ============================================================================
# SECTION 19: Main Installation
# ============================================================================

# Phase 0: Welcome banner and user confirmation
install_show_welcome() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo -e "  ${BOLD}hypr-login Installer${NC}"
    echo "  Boot directly into Hyprland with hyprlock as login screen"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo -e "  ${YELLOW}⚠️  WARNING: This modifies your boot process!${NC}"
    echo ""
    echo "  What this installer does:"
    echo "    • Configures TTY autologin (replaces SDDM)"
    echo "    • Installs Fish shell hooks to auto-start Hyprland"
    echo "    • Guides you to add hyprlock to your config"
    echo ""
    echo "  Requirements:"
    echo "    • Hyprland, hyprlock, Fish shell installed"
    echo "    • Willingness to test on tty2 before full cutover"
    echo ""
    echo "  Installation phases:"
    echo "    1. Pre-flight checks (dependencies, source files)"
    echo "    2. System detection (GPU, display, session method)"
    echo "    3. User-level install (scripts, fish hook)"
    echo "    4. System-level install (systemd autologin)"
    echo "    5. Staged testing (verify on tty2)"
    echo "    6. SDDM cutover (disable display manager)"
    echo ""

    if $DRY_RUN; then
        echo -e "  ${CYAN}[DRY-RUN MODE]${NC} No files will be modified"
        echo ""
    fi

    # Use ask() (defaults to No) - installation modifies system, requires explicit opt-in
    if ! ask "Continue with installation?"; then
        info "Installation cancelled"
        exit 0
    fi
}

# Phase 1: Pre-flight checks
install_preflight_checks() {
    echo ""
    info "Running pre-flight checks..."
    validate_dependencies
    validate_source_files

    if is_fully_installed; then
        warn "hypr-login appears to be already installed"
        if ask "Run update instead?"; then
            update
            return 1  # Signal to caller to exit install flow
        fi
    fi
    return 0
}

# Phase 2: System detection and user confirmation
install_detect_system() {
    echo ""
    info "Detecting system configuration..."
    detect_username
    detect_gpus
    detect_display_outputs
    detect_hyprland_config
    detect_hyprlock_in_config

    # Present and confirm
    present_username
    present_gpu_options
    present_display_options
    present_config_info
    present_session_method

    # Validate SESSION_METHOD was set (defense in depth)
    if [[ -z "$SESSION_METHOD" ]] || [[ ! "$SESSION_METHOD" =~ ^(exec-once|uwsm)$ ]]; then
        error "SESSION_METHOD not set or invalid after detection - this is a bug"
        exit 1
    fi

    present_detection_summary

    # Save configuration for future updates (non-fatal if fails)
    if ! save_install_config; then
        warn "Could not save config - future updates may require re-detection"
    fi
}

# Phase 3: User-level component installation
install_user_components() {
    echo ""
    info "Installing user-level components..."
    CRITICAL_OPERATION="installing launcher script"
    install_launcher_script || { error "Launcher script installation failed - aborting"; exit 1; }
    CRITICAL_OPERATION="installing fish hook"
    install_fish_hook || { error "Fish hook installation failed - aborting"; exit 1; }
    CRITICAL_OPERATION=""

    # Install hyprlock service for UWSM users
    if [[ "$SESSION_METHOD" == "uwsm" ]]; then
        CRITICAL_OPERATION="installing hyprlock service"
        install_hyprlock_service || { error "Hyprlock service installation failed - aborting"; exit 1; }
        CRITICAL_OPERATION=""
    fi

    # Show hyprlock setup instructions (conditional on session method)
    present_execs_instructions
}

# Phase 4-6: System-level installation, testing, and cutover
install_system_components() {
    if request_sudo; then
        CRITICAL_OPERATION="configuring systemd autologin"
        create_autologin_override || { CRITICAL_OPERATION=""; error "Failed to configure autologin"; return 1; }
        CRITICAL_OPERATION=""

        # Phase 4: Staged testing
        if ! setup_tty2_testing; then
            # User chose not to continue after getty failure
            echo ""
            error "Staged testing aborted - cannot proceed without tty2"
            echo "  Fix the issue and re-run: ./setup.sh"
            return 1
        fi
        guide_tty2_test
        confirm_test_passed

        # Phase 5: SDDM cutover
        confirm_sddm_disable
        CRITICAL_OPERATION="disabling SDDM (display manager)"
        disable_sddm || { CRITICAL_OPERATION=""; error "Failed to disable SDDM"; return 1; }
        CRITICAL_OPERATION=""
        present_final_instructions
    else
        echo ""
        warn "System-level installation skipped"
        echo ""
        echo "  User-level components are installed."
        echo "  To complete installation manually:"
        echo "    1. Create $SYSTEMD_OVERRIDE_DEST"
        echo "    2. Run: sudo systemctl daemon-reload"
        echo "    3. Test on tty2"
        echo "    4. Disable SDDM: sudo systemctl disable sddm"
        echo ""
    fi
}

# Main installation orchestrator
install() {
    install_show_welcome
    install_preflight_checks || return
    install_detect_system
    install_user_components
    install_system_components
}

# ============================================================================
# SECTION 20: Argument Parsing
# ============================================================================

SOURCE_ONLY=false

for arg in "$@"; do
    case "$arg" in
        -h|--help)      show_help ;;
        -n|--dry-run)   DRY_RUN=true ;;
        -u|--uninstall) UNINSTALL=true ;;
        -d|--update)    UPDATE_MODE=true ;;
        --skip-test)    SKIP_TEST=true ;;
        --source-only)  SOURCE_ONLY=true ;;  # For testing: load functions without running
        *)
            error "Unknown option: $arg"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# ============================================================================
# SECTION 21: Entry Point
# ============================================================================

# Skip execution when sourced for testing
$SOURCE_ONLY && return 0 2>/dev/null || $SOURCE_ONLY && exit 0

if $UNINSTALL; then
    uninstall
elif $UPDATE_MODE; then
    update
else
    install
fi
