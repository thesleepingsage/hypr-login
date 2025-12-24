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

set -eu

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

# Script directory (where this script lives)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Installation paths
LAUNCHER_DEST="$HOME/.config/hypr/scripts/hyprland-tty.fish"
FISH_HOOK_DEST="$HOME/.config/fish/conf.d/hyprland-autostart.fish"
SYSTEMD_OVERRIDE_DIR="/etc/systemd/system/getty@tty1.service.d"
SYSTEMD_OVERRIDE_FILE="$SYSTEMD_OVERRIDE_DIR/autologin.conf"
CONFIG_DIR="$HOME/.config/hypr-login"
CONFIG_FILE="$CONFIG_DIR/install.conf"

# Source files
LAUNCHER_SRC="$SCRIPT_DIR/scripts/fish/hyprland-tty.fish"
FISH_HOOK_SRC="$SCRIPT_DIR/scripts/fish/hyprland-autostart.fish"

# Detected values (populated during detection phase)
DETECTED_USERNAME=""
DETECTED_GPU_TYPE=""
DETECTED_GPUS=()
DETECTED_DRM_PATH=""
DETECTED_OUTPUTS=()
DETECTED_EXECS_FILES=()
HYPRLOCK_CONFIGURED_FILES=()
HYPR_CONFIG_DIR=""

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

    # Clean up any temp files that might exist
    rm -f /tmp/hypr-login-*.tmp 2>/dev/null || true

    exit $exit_code
}

# Set up trap for common interrupt signals
trap cleanup_on_interrupt INT TERM

# ============================================================================
# SECTION 5: Concurrent Execution Lock
# ============================================================================

# Prevent multiple instances from running simultaneously
LOCK_FILE="/tmp/hypr-login-install.lock"
acquire_lock() {
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        error "Another hypr-login installation is already running"
        echo "  If this is incorrect, remove: $LOCK_FILE"
        exit 1
    fi
}
acquire_lock
trap 'flock -u 200 2>/dev/null; cleanup_on_interrupt' INT TERM

# ============================================================================
# SECTION 6: Helper Functions
# ============================================================================

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }

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
# Usage: select_from_menu "Choose an option:" "opt1" "opt2" "opt3"
# Returns: Sets SELECT_RESULT to selected value, SELECT_INDEX to 1-based index
# Returns 0 on valid selection, 1 on invalid/empty
SELECT_RESULT=""
SELECT_INDEX=0
select_from_menu() {
    local prompt="$1"
    shift
    local options=("$@")
    local i=1

    for opt in "${options[@]}"; do
        echo "    $i) $opt"
        ((i++))
    done
    echo ""
    echo -n "  $prompt [1-${#options[@]}]: "
    read -r choice

    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#options[@]} ]]; then
        SELECT_INDEX=$choice
        SELECT_RESULT="${options[$((choice-1))]}"
        return 0
    else
        SELECT_INDEX=0
        SELECT_RESULT=""
        return 1
    fi
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
    local backup="${file}.backup.$(date +%Y%m%d_%H%M%S_%N)"

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
    [[ -s "$SYSTEMD_OVERRIDE_FILE" ]] || return 1

    # Validate it contains the autologin flag (core functionality)
    grep -q -- '--autologin' "$SYSTEMD_OVERRIDE_FILE" || return 1

    # Ensure placeholder was replaced (not still "YOUR_USERNAME")
    ! grep -q 'YOUR_USERNAME' "$SYSTEMD_OVERRIDE_FILE"
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
    # Use timeout to prevent hanging if systemd is unresponsive
    timeout 3 systemctl is-enabled sddm &>/dev/null
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
load_install_config() {
    [[ -f "$CONFIG_FILE" ]] || return 1

    # Validate config file syntax before sourcing (security + corruption check)
    if ! bash -n "$CONFIG_FILE" 2>/dev/null; then
        warn "Config file has syntax errors: $CONFIG_FILE"
        warn "Ignoring saved configuration - will use fresh detection"
        return 1
    fi

    # shellcheck source=/dev/null
    source "$CONFIG_FILE" 2>/dev/null || {
        warn "Failed to load config file"
        return 1
    }

    # Validate loaded values are in expected range
    if [[ -n "$SESSION_METHOD" ]] && [[ "$SESSION_METHOD" != "exec-once" && "$SESSION_METHOD" != "uwsm" ]]; then
        warn "Invalid SESSION_METHOD in config: $SESSION_METHOD"
        unset SESSION_METHOD
    fi

    return 0
}

# ============================================================================
# SECTION 10: Dependency Checking
# ============================================================================

check_dependencies() {
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
}

check_source_files() {
    # Check launcher script
    if [[ ! -f "$LAUNCHER_SRC" ]]; then
        error "Source file not found: $LAUNCHER_SRC"
        echo "  Make sure you're running from the hypr-login directory"
        exit 1
    fi
    if [[ ! -s "$LAUNCHER_SRC" ]]; then
        error "Source file is empty: $LAUNCHER_SRC"
        exit 1
    fi
    if [[ ! -r "$LAUNCHER_SRC" ]]; then
        error "Source file not readable: $LAUNCHER_SRC"
        exit 1
    fi

    # Check fish hook script
    if [[ ! -f "$FISH_HOOK_SRC" ]]; then
        error "Source file not found: $FISH_HOOK_SRC"
        exit 1
    fi
    if [[ ! -s "$FISH_HOOK_SRC" ]]; then
        error "Source file is empty: $FISH_HOOK_SRC"
        exit 1
    fi
    if [[ ! -r "$FISH_HOOK_SRC" ]]; then
        error "Source file not readable: $FISH_HOOK_SRC"
        exit 1
    fi

    success "Source files found and verified"
}

# ============================================================================
# SECTION 11: System Detection
# ============================================================================

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

detect_gpus() {
    DETECTED_GPUS=()

    for card_dir in /sys/class/drm/card*; do
        [[ -d "$card_dir/device" ]] || continue

        local card_name
        card_name=$(basename "$card_dir")

        # Only base cards (card0, card1), not outputs (card0-DP-1)
        [[ "$card_name" =~ ^card[0-9]+$ ]] || continue

        local driver_path driver_name
        driver_path=$(readlink -f "$card_dir/device/driver" 2>/dev/null || echo "unknown")
        driver_name=$(basename "$driver_path")

        DETECTED_GPUS+=("$card_name:$driver_name")
    done
}

detect_display_outputs() {
    DETECTED_OUTPUTS=()

    for drm_file in /run/udev/data/+drm:card*-*; do
        [[ -e "$drm_file" ]] || continue
        DETECTED_OUTPUTS+=("$drm_file")
    done
}

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
        echo -n "Enter username: "
        read -r DETECTED_USERNAME

        if ! id "$DETECTED_USERNAME" &>/dev/null; then
            error "User '$DETECTED_USERNAME' does not exist"
            exit 1
        fi
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

# Classify detected GPUs and display them
# Sets: GPU_TYPES_IN_ORDER (array of "value:Label" pairs in detection order), GPU_TYPE_COUNT
# Also warns about unrecognized drivers and duplicate GPU types
GPU_TYPES_IN_ORDER=()
GPU_TYPE_COUNT=0
classify_detected_gpus() {
    GPU_TYPES_IN_ORDER=()
    GPU_TYPE_COUNT=0
    local -A seen=()
    local -A driver_count=()
    local unknown_drivers=()

    # First pass: count drivers and display cards
    for gpu in "${DETECTED_GPUS[@]}"; do
        local card="${gpu%%:*}"
        local driver="${gpu##*:}"

        # Track driver occurrences for duplicate detection
        ((driver_count[$driver]++)) || driver_count[$driver]=1

        # Display with card number prominently
        if [[ -v "GPU_DRIVER_MAP[$driver]" ]]; then
            local label="${GPU_DRIVER_MAP[$driver]##*:}"
            echo "    • $card: $label ($driver driver)"
        else
            echo "    • $card: $driver (unknown driver)"
            if [[ ! " ${unknown_drivers[*]} " =~ " $driver " ]]; then
                unknown_drivers+=("$driver")
            fi
        fi
    done

    # Warn about unrecognized GPU drivers
    if [[ ${#unknown_drivers[@]} -gt 0 ]]; then
        echo ""
        warn "Unrecognized GPU driver(s): ${unknown_drivers[*]}"
        echo "      Known drivers: ${!GPU_DRIVER_MAP[*]}"
        echo "      GPU env vars will use auto-detection for unknown drivers"
    fi

    # Check for duplicate GPU types (e.g., two NVIDIA cards)
    for driver in "${!driver_count[@]}"; do
        if [[ ${driver_count[$driver]} -gt 1 ]] && [[ -v "GPU_DRIVER_MAP[$driver]" ]]; then
            echo ""
            info "Multiple ${GPU_DRIVER_MAP[$driver]##*:} GPUs detected (${driver_count[$driver]} cards)"
            echo "      Pay attention to Display Output selection to target the correct card"
        fi
    done

    # Second pass: build selection list
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
    echo -n "  Choose [1-${#options[@]}]: "
    read -r gpu_choice

    if [[ "$gpu_choice" =~ ^[0-9]+$ ]] && [[ "$gpu_choice" -ge 1 ]] && [[ "$gpu_choice" -le ${#options[@]} ]]; then
        DETECTED_GPU_TYPE="${options[$((gpu_choice-1))]}"
    else
        warn "Invalid choice, using auto-detection"
        DETECTED_GPU_TYPE="auto"
    fi
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
    echo -n "  Choose primary display [1-$i]: "
    read -r display_choice

    if [[ "$display_choice" == "$i" ]] || [[ -z "$display_choice" ]]; then
        DETECTED_DRM_PATH="auto"
    elif [[ "$display_choice" =~ ^[0-9]+$ ]] && [[ "$display_choice" -ge 1 ]] && [[ "$display_choice" -lt $i ]]; then
        DETECTED_DRM_PATH="${DETECTED_OUTPUTS[$((display_choice-1))]}"
    else
        DETECTED_DRM_PATH="auto"
    fi

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
            local rel_path="${file#$HOME/}"
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
            local rel_path="${file#$HOME/}"
            echo "    • ~/$rel_path"
        done
    fi
}

# Check if UWSM is active (for auto-detection helper)
# Uses timeout to prevent hanging if systemd is unresponsive
check_uwsm_status() {
    local status
    # 3-second timeout prevents indefinite hang
    status=$(timeout 3 systemctl --user is-active uwsm-app@Hyprland.service 2>&1) || status="timeout"

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

# Present session method selection (UWSM vs exec-once)
# Sets: SESSION_METHOD to "exec-once" or "uwsm"
present_session_method() {
    # Generous limit - user may need multiple attempts to understand
    local max_help_attempts=10
    local help_attempts=0

    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo -e "  ${BOLD}SESSION METHOD: How do you start Hyprland?${NC}"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo -e "  ${YELLOW}⚠️  Choosing the wrong method will prevent hyprlock from starting!${NC}"
    echo ""
    echo -e "  ${CYAN}WHAT IS UWSM?${NC}"
    echo "    UWSM (Universal Wayland Session Manager) runs Hyprland via systemd."
    echo "    If you run 'uwsm start hyprland' or use a UWSM display manager, choose 2."
    echo ""
    echo -e "  ${CYAN}WHAT IS EXEC-ONCE?${NC}"
    echo "    This is the traditional method where Hyprland starts from ~/.config/hypr/"
    echo "    If you log into TTY and Hyprland auto-starts, choose 1."
    echo ""
    echo "  ─────────────────────────────────────────────────────────────────"
    echo ""
    echo "    1) Direct/TTY autologin (exec-once method)"
    echo "       • You log into a TTY and Hyprland starts automatically"
    echo "       • Your startup is configured in ~/.config/hypr/execs.conf"
    echo ""
    echo "    2) UWSM managed session (systemd service method)"
    echo "       • You use 'uwsm start hyprland' or SDDM/GDM with UWSM"
    echo "       • Hyprland runs as a systemd user service"
    echo ""
    echo "    3) I don't know / Not sure"
    echo "       • Let the installer detect your current setup"
    echo ""

    while true; do
        echo -n "  Choose [1-3]: "
        read -r method_choice

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
            3)
                ((help_attempts++))
                if ((help_attempts >= max_help_attempts)); then
                    echo ""
                    error "Maximum help attempts reached ($max_help_attempts)"
                    echo "  Please determine your session method and re-run the installer."
                    echo "  Hint: Run 'systemctl --user is-active uwsm-app@Hyprland.service'"
                    echo ""
                    exit 1
                fi

                present_session_method_help
                # If help flow auto-detected and set SESSION_METHOD, we're done
                if [[ -n "$SESSION_METHOD" ]]; then
                    return 0
                fi
                # Otherwise, loop back to main selection
                echo ""
                echo "    1) Direct/TTY autologin (exec-once method)"
                echo "    2) UWSM managed session (systemd service method)"
                echo "    3) I don't know / Not sure"
                echo ""
                ;;
            *)
                warn "Invalid choice. Please enter 1, 2, or 3."
                ;;
        esac
    done
}

# Help flow for users who don't know their session method
present_session_method_help() {
    echo ""
    echo "  Would you like us to check your system?"
    echo ""
    echo "    1) Yes, check my system"
    echo "    2) No, I'll figure it out myself"
    echo ""
    echo -n "  Choose [1-2]: "
    read -r help_choice

    case "$help_choice" in
        1)
            echo ""
            info "Checking for UWSM..."
            local uwsm_status
            uwsm_status=$(check_uwsm_status)

            case "$uwsm_status" in
                active)
                    echo ""
                    echo -e "  ${GREEN}Result: UWSM is active${NC}"
                    echo "  → Auto-selecting UWSM method..."
                    SESSION_METHOD="uwsm"
                    success "Session method: uwsm (auto-detected)"
                    return 0  # Exit help flow with method set
                    ;;
                inactive|not-found)
                    echo ""
                    if [[ "$uwsm_status" == "inactive" ]]; then
                        echo -e "  ${CYAN}Result: UWSM service exists but is inactive${NC}"
                    else
                        echo -e "  ${CYAN}Result: UWSM not installed or not configured${NC}"
                    fi
                    echo "  → Auto-selecting exec-once method..."
                    SESSION_METHOD="exec-once"
                    success "Session method: exec-once (auto-detected)"
                    return 0  # Exit help flow with method set
                    ;;
                failed)
                    echo ""
                    echo -e "  ${YELLOW}Result: UWSM service exists but is in failed state${NC}"
                    echo "  → Cannot auto-detect. Please select manually."
                    ;;
            esac
            echo ""
            read -p "  Press Enter to continue..."
            ;;
        2)
            echo ""
            echo "  To figure out which method you use:"
            echo ""
            echo "    • If you installed via this project's TTY autologin → Option 1"
            echo "    • If you run 'uwsm start hyprland' → Option 2"
            echo "    • If you use a display manager with UWSM → Option 2"
            echo "    • If Hyprland starts from your .bashrc/.zshrc/.config/fish → Option 1"
            echo ""
            echo "  Re-run the installer when you know your setup."
            echo ""
            if ! ask "Continue anyway?"; then
                info "Installation cancelled"
                exit 0
            fi
            # User chose to continue without knowing - they must still select a method
            return 1
            ;;
        *)
            warn "Invalid choice"
            return 1
            ;;
    esac
    return 0
}

show_detection_summary() {
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

install_launcher_script() {
    local dest_dir
    dest_dir=$(dirname "$LAUNCHER_DEST")

    if dry_run_preview "Would create: $LAUNCHER_DEST"; then
        return 0
    fi

    mkdir -p "$dest_dir" || { error "Failed to create directory: $dest_dir"; return 1; }

    # Use temp file for atomic operations - only move to final destination if all succeeds
    local temp_file
    temp_file=$(mktemp) || { error "Failed to create temp file"; return 1; }
    trap "rm -f '$temp_file'" RETURN

    # Copy the base script to temp file
    cp "$LAUNCHER_SRC" "$temp_file" || { error "Failed to copy launcher script"; return 1; }

    # Uncomment the appropriate GPU section based on detection
    # All sed operations happen on temp file - atomic application
    case "$DETECTED_GPU_TYPE" in
        nvidia)
            info "Configuring NVIDIA GPU settings..."
            sed -i 's/^# set -gx LIBVA_DRIVER_NAME nvidia/set -gx LIBVA_DRIVER_NAME nvidia/' "$temp_file" &&
            sed -i 's/^# set -gx __GLX_VENDOR_LIBRARY_NAME nvidia/set -gx __GLX_VENDOR_LIBRARY_NAME nvidia/' "$temp_file" &&
            sed -i 's/^# set -gx NVD_BACKEND direct/set -gx NVD_BACKEND direct/' "$temp_file" ||
            { error "Failed to configure NVIDIA GPU settings"; return 1; }
            ;;
        amd)
            info "Configuring AMD GPU settings..."
            sed -i 's/^# set -gx LIBVA_DRIVER_NAME radeonsi/set -gx LIBVA_DRIVER_NAME radeonsi/' "$temp_file" ||
            { error "Failed to configure AMD GPU settings"; return 1; }
            ;;
        intel)
            info "Configuring Intel GPU settings..."
            sed -i 's/^# set -gx LIBVA_DRIVER_NAME iHD/set -gx LIBVA_DRIVER_NAME iHD/' "$temp_file" ||
            { error "Failed to configure Intel GPU settings"; return 1; }
            ;;
        auto|*)
            info "GPU type 'auto' - leaving configuration for runtime detection"
            ;;
    esac

    # If specific DRM path was chosen, add it to the script
    if [[ "$DETECTED_DRM_PATH" != "auto" ]]; then
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
    fi

    chmod +x "$temp_file" || { error "Failed to make script executable"; return 1; }

    # Security: Check for symlink at destination (TOCTOU mitigation)
    if [[ -L "$LAUNCHER_DEST" ]]; then
        warn "Removing existing symlink at destination: $LAUNCHER_DEST"
        rm -f "$LAUNCHER_DEST" || { error "Failed to remove symlink"; return 1; }
    fi

    # Atomic move: only replace destination if all above succeeded
    mv "$temp_file" "$LAUNCHER_DEST" || { error "Failed to install launcher script"; return 1; }
    trap - RETURN  # Clear the trap since move succeeded
    success "Launcher script installed: $LAUNCHER_DEST"
}

install_fish_hook() {
    local dest_dir
    dest_dir=$(dirname "$FISH_HOOK_DEST")

    if dry_run_preview "Would create: $FISH_HOOK_DEST"; then
        return 0
    fi

    mkdir -p "$dest_dir" || { error "Failed to create directory: $dest_dir"; return 1; }

    # Use temp file for atomic installation
    local temp_file
    temp_file=$(mktemp) || { error "Failed to create temp file"; return 1; }
    trap "rm -f '$temp_file'" RETURN

    cp "$FISH_HOOK_SRC" "$temp_file" || { error "Failed to copy fish hook"; return 1; }

    # Security: Check for symlink at destination (TOCTOU mitigation)
    if [[ -L "$FISH_HOOK_DEST" ]]; then
        warn "Removing existing symlink at destination: $FISH_HOOK_DEST"
        rm -f "$FISH_HOOK_DEST" || { error "Failed to remove symlink"; return 1; }
    fi

    # Atomic move: only replace destination if copy succeeded
    mv "$temp_file" "$FISH_HOOK_DEST" || { error "Failed to install fish hook"; return 1; }
    trap - RETURN  # Clear trap since move succeeded

    success "Fish hook installed: $FISH_HOOK_DEST"
}

# Install hyprlock as a systemd user service (for UWSM method)
install_hyprlock_service() {
    local dest_dir
    dest_dir=$(dirname "$HYPRLOCK_SERVICE_DEST")

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
    timeout 5 systemctl --user daemon-reload || { error "Failed to reload user systemd (timeout)"; return 1; }

    # Verify service is loadable before enabling
    if ! timeout 3 systemctl --user cat hyprlock.service >/dev/null 2>&1; then
        error "Systemd cannot load hyprlock.service - check file format"
        return 1
    fi

    timeout 5 systemctl --user enable hyprlock.service || { error "Failed to enable hyprlock service (timeout)"; return 1; }

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
    timeout 5 systemctl --user disable hyprlock.service 2>/dev/null || true
    rm -f "$HYPRLOCK_SERVICE_DEST" || { warn "Could not remove service file"; }
    timeout 5 systemctl --user daemon-reload || { warn "Failed to reload user systemd"; }

    success "Removed hyprlock systemd service"
}

# Show instructions for hyprlock setup based on session method
# For exec-once: Guide user to add exec-once = hyprlock to config
# For UWSM: Service is already installed, just confirm
show_execs_instructions() {
    # UWSM method: Service is already enabled, no manual config needed
    if [[ "$SESSION_METHOD" == "uwsm" ]]; then
        echo ""
        echo "═══════════════════════════════════════════════════════════════════"
        echo -e "  ${GREEN}${BOLD}✓ HYPRLOCK SERVICE CONFIGURED${NC}"
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
        read -p "Press Enter to continue..."
        return
    fi

    # exec-once method: Guide user to add line to config

    # Prevent hybrid configuration: warn if UWSM service already exists
    if is_hyprlock_service_installed; then
        echo ""
        echo "═══════════════════════════════════════════════════════════════════"
        echo -e "  ${RED}${BOLD}⚠️  HYBRID CONFIGURATION DETECTED${NC}"
        echo "═══════════════════════════════════════════════════════════════════"
        echo ""
        echo "  A hyprlock systemd service is already installed (UWSM method)."
        echo "  Adding exec-once = hyprlock would create a HYBRID configuration"
        echo "  where hyprlock starts TWICE - this will cause problems!"
        echo ""
        echo "  Options:"
        echo "    1) Remove the service first: systemctl --user disable hyprlock.service"
        echo "    2) Or switch to UWSM method: re-run installer and choose option 2"
        echo ""
        if ! ask "Continue anyway? (NOT RECOMMENDED)"; then
            info "Skipping hyprlock configuration to prevent hybrid setup"
            echo ""
            read -p "Press Enter to continue..."
            return
        fi
        warn "Proceeding with hybrid configuration - you may experience issues"
    fi

    # Check if already configured and offer to skip
    if [[ ${#HYPRLOCK_CONFIGURED_FILES[@]} -gt 0 ]]; then
        echo ""
        echo "═══════════════════════════════════════════════════════════════════"
        echo -e "  ${YELLOW}${BOLD}⚠️  HYPRLOCK ALREADY CONFIGURED${NC}"
        echo "═══════════════════════════════════════════════════════════════════"
        echo ""
        echo "  Found existing hyprlock configuration in:"
        for file in "${HYPRLOCK_CONFIGURED_FILES[@]}"; do
            local rel_path="${file#$HOME/}"
            echo "      • ~/$rel_path"
        done
        echo ""

        if ! ask "Add hyprlock to config anyway? (creates duplicate)"; then
            success "Skipping hyprlock configuration (already present)"
            echo ""
            read -p "Press Enter to continue..."
            return
        fi
        warn "Proceeding - you may have duplicate hyprlock entries"
    fi

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
            local rel_path="${file#$HOME/}"
            echo "      • ~/$rel_path"
        done
        echo ""
        echo -e "  Choose one that is ${BOLD}NOT${NC} overwritten by dotfile updates"
        echo "  (usually in custom.d/ or similar)"
    fi

    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    # Only offer EDITOR if it's set AND executable
    if [[ -n "${EDITOR:-}" ]] && command -v "$EDITOR" >/dev/null 2>&1 && ask "Open your config in \$EDITOR ($EDITOR)?"; then
        if [[ ${#DETECTED_EXECS_FILES[@]} -eq 1 ]]; then
            "$EDITOR" "${DETECTED_EXECS_FILES[0]}"
        elif [[ ${#DETECTED_EXECS_FILES[@]} -gt 1 ]]; then
            echo ""
            echo "  Which file to edit?"
            if select_from_menu "Choose" "${DETECTED_EXECS_FILES[@]}"; then
                "$EDITOR" "$SELECT_RESULT"
            fi
        fi
    fi

    echo ""
    read -p "Press Enter when you've added the line..."
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

    if ! ask_yes "Proceed with sudo operations?"; then
        warn "Skipping system-level configuration"
        echo ""
        echo "  You'll need to manually create: $SYSTEMD_OVERRIDE_FILE"
        echo "  And run: sudo systemctl daemon-reload"
        return 1
    fi

    # Test sudo access
    if ! sudo -v; then
        error "Failed to get sudo access"
        return 1
    fi

    return 0
}

create_autologin_override() {
    if dry_run_preview "Would create: $SYSTEMD_OVERRIDE_FILE"; then
        return 0
    fi

    sudo mkdir -p "$SYSTEMD_OVERRIDE_DIR" || { error "Failed to create systemd override directory"; return 1; }

    # Backup existing override file before modification
    if [[ -f "$SYSTEMD_OVERRIDE_FILE" ]]; then
        local backup_file="${SYSTEMD_OVERRIDE_FILE}.backup.$(date +%Y%m%d_%H%M%S_%N)"
        sudo cp -p "$SYSTEMD_OVERRIDE_FILE" "$backup_file" || warn "Failed to backup existing override file"
        info "Backed up existing config to: $backup_file"
    fi

    cat << EOF | sudo tee "$SYSTEMD_OVERRIDE_FILE" > /dev/null || { error "Failed to write autologin config"; return 1; }
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty -o "-p -f -- \\u" --noclear --autologin "$DETECTED_USERNAME" %I \$TERM
EOF

    # Use timeout to prevent hang if systemd is unresponsive
    sudo timeout 5 systemctl daemon-reload || { error "Failed to reload systemd daemon (timeout)"; return 1; }

    # Validate the systemd config can be parsed (catches syntax errors early)
    if ! sudo timeout 3 systemctl cat getty@tty1.service >/dev/null 2>&1; then
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
    if sudo systemctl start getty@tty2 2>/dev/null; then
        success "getty@tty2 started"
    elif systemctl is-active getty@tty2 >/dev/null 2>&1; then
        info "getty@tty2 already running"
    else
        warn "Could not start getty@tty2 - you may need to start it manually"
        warn "Try: sudo systemctl start getty@tty2"
        return 1
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
    echo -e "  ${YELLOW}If the test FAILS:${NC}"
    echo "    • Press Ctrl+C during the 10-second restart delay"
    echo "    • Check ~/.hyprland.log for errors"
    echo "    • Return here to troubleshoot"
    echo ""

    read -p "Press Enter when ready to test (then switch to tty2)..."
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

    while true; do
        if ask "Did the tty2 test SUCCEED? (Hyprland started, hyprlock appeared)"; then
            success "Test passed! Ready for SDDM cutover"
            return 0
        fi

        warn "Test did not pass"
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
                read -p "Press Enter to continue..."
                ;;
            2)
                "${EDITOR:-nano}" "$LAUNCHER_DEST"
                ;;
            3)
                guide_tty2_test
                ;;
            4)
                info "Exiting - SDDM not modified"
                echo ""
                echo "  User-level components are installed."
                echo "  Fix issues and re-run installer when ready."
                exit 0
                ;;
            *)
                warn "Invalid choice. Please enter 1-4."
                ;;
        esac
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
        sudo timeout 5 systemctl disable sddm || { error "Failed to disable SDDM (timeout)"; return 1; }
        success "SDDM disabled"
    else
        info "SDDM was already disabled"
    fi
}

show_final_instructions() {
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
    echo "    • $SYSTEMD_OVERRIDE_FILE"
    echo ""

    if ask_yes "Reboot now?"; then
        sudo reboot || {
            error "Reboot command failed"
            echo "  Run manually: sudo reboot"
        }
    else
        info "Remember to reboot to apply changes"
    fi
}

# ============================================================================
# SECTION 17: Uninstall Functions
# ============================================================================

uninstall() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo -e "  ${BOLD}UNINSTALL hypr-login${NC}"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    # Load saved configuration to know which method was used
    local was_uwsm=false
    if load_install_config && [[ "$SESSION_METHOD" == "uwsm" ]]; then
        was_uwsm=true
        info "Detected UWSM installation"
    elif is_hyprlock_service_installed; then
        was_uwsm=true
        info "Detected hyprlock systemd service"
    fi

    if ! ask_yes "Remove all hypr-login components?"; then
        info "Uninstall cancelled"
        exit 0
    fi

    echo ""

    # Remove user-level components
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
    local -a backup_dirs=("$LOCAL_BIN" "$FISH_CONF_DIR" "$HYPRLOCK_SERVICE_DEST")

    for dir in "${backup_dirs[@]}"; do
        local parent_dir
        parent_dir=$(dirname "$dir")
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

    # Remove systemd override (requires sudo)
    if [[ -f "$SYSTEMD_OVERRIDE_FILE" ]]; then
        if ask_yes "Remove systemd autologin override? (requires sudo)"; then
            if $DRY_RUN; then
                echo "$(dry_run_prefix)Would remove: $SYSTEMD_OVERRIDE_FILE"
            else
                sudo rm -f "$SYSTEMD_OVERRIDE_FILE"
                sudo timeout 5 systemctl daemon-reload || warn "Systemd reload timed out"
                success "Removed systemd override"
            fi
        fi
    fi

    echo ""
    echo -e "  ${YELLOW}Remaining manual steps:${NC}"
    if $was_uwsm; then
        echo "    1. (UWSM method) No manual hyprlock config changes needed"
    else
        echo "    1. Remove 'exec-once = hyprlock' from your execs.conf"
    fi
    echo -e "    2. Re-enable SDDM: ${CYAN}sudo systemctl enable sddm${NC}"
    echo "    3. Reboot"
    echo ""

    if ask_yes "Enable SDDM now?"; then
        if $DRY_RUN; then
            echo "$(dry_run_prefix)Would run: sudo systemctl enable sddm"
        else
            sudo timeout 5 systemctl enable sddm || { error "Failed to enable SDDM (timeout)"; }
            success "SDDM re-enabled"
        fi
    fi

    echo ""
    success "Uninstall complete"

    if ask_yes "Reboot now?"; then
        sudo reboot
    fi
}

# ============================================================================
# SECTION 18: Update Mode
# ============================================================================

update() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo -e "  ${BOLD}UPDATE hypr-login${NC}"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

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

    check_source_files

    # Backup and update launcher
    if is_launcher_installed; then
        backup_file "$LAUNCHER_DEST"
    fi

    # Re-run detection for GPU settings
    detect_gpus
    present_gpu_options

    # Install updated files
    install_launcher_script
    install_fish_hook

    # Update hyprlock service if UWSM method was used
    if [[ "$SESSION_METHOD" == "uwsm" ]] || is_hyprlock_service_installed; then
        if is_hyprlock_service_installed; then
            info "Updating hyprlock systemd service..."
            backup_file "$HYPRLOCK_SERVICE_DEST"
            install_hyprlock_service
        elif [[ "$SESSION_METHOD" == "uwsm" ]]; then
            info "Installing hyprlock systemd service (UWSM method)..."
            install_hyprlock_service
        fi
    fi

    # Check systemd configuration
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

    echo ""
    success "Update complete"
    info "Restart your shell or reboot to apply changes"
}

# ============================================================================
# SECTION 19: Main Installation
# ============================================================================

install() {
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

    if ! ask_yes "Continue with installation?"; then
        info "Installation cancelled"
        exit 0
    fi

    # Pre-flight checks
    echo ""
    info "Running pre-flight checks..."
    check_dependencies
    check_source_files

    if is_fully_installed; then
        warn "hypr-login appears to be already installed"
        if ask "Run update instead?"; then
            update
            return
        fi
    fi

    # System detection
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
    show_detection_summary

    # Save configuration for future updates
    save_install_config

    # Phase 2: User-level installation
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
    show_execs_instructions

    # Phase 3: System-level installation
    if request_sudo; then
        CRITICAL_OPERATION="configuring systemd autologin"
        create_autologin_override
        CRITICAL_OPERATION=""

        # Phase 4: Staged testing
        setup_tty2_testing
        guide_tty2_test
        confirm_test_passed

        # Phase 5: SDDM cutover
        confirm_sddm_disable
        CRITICAL_OPERATION="disabling SDDM (display manager)"
        disable_sddm
        CRITICAL_OPERATION=""
        show_final_instructions
    else
        echo ""
        warn "System-level installation skipped"
        echo ""
        echo "  User-level components are installed."
        echo "  To complete installation manually:"
        echo "    1. Create $SYSTEMD_OVERRIDE_FILE"
        echo "    2. Run: sudo systemctl daemon-reload"
        echo "    3. Test on tty2"
        echo "    4. Disable SDDM: sudo systemctl disable sddm"
        echo ""
    fi
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
