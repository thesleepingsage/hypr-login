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
HYPR_CONFIG_DIR=""

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
# SECTION 4: Helper Functions
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
# SECTION 5: Path Normalization
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
# SECTION 6: Safe File Operations
# ============================================================================

# Create timestamped backup
backup_file() {
    local file="$1"
    local backup="${file}.backup.$(date +%Y%m%d_%H%M%S)"

    if [[ -f "$file" ]]; then
        if dry_run_preview "Would backup: $file → $backup"; then
            return 0
        fi
        cp "$file" "$backup"
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
        rm -rf "$path"
        success "Removed $description"
    fi
}

# ============================================================================
# SECTION 7: Installation Detection
# ============================================================================

is_launcher_installed() {
    [[ -f "$LAUNCHER_DEST" ]]
}

is_fish_hook_installed() {
    [[ -f "$FISH_HOOK_DEST" ]]
}

is_systemd_configured() {
    [[ -f "$SYSTEMD_OVERRIDE_FILE" ]]
}

is_fully_installed() {
    is_launcher_installed && is_fish_hook_installed && is_systemd_configured
}

is_sddm_enabled() {
    systemctl is-enabled sddm &>/dev/null
}

# ============================================================================
# SECTION 8: Dependency Checking
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
    if [[ ! -f "$LAUNCHER_SRC" ]]; then
        error "Source file not found: $LAUNCHER_SRC"
        echo "  Make sure you're running from the hypr-login directory"
        exit 1
    fi

    if [[ ! -f "$FISH_HOOK_SRC" ]]; then
        error "Source file not found: $FISH_HOOK_SRC"
        exit 1
    fi

    success "Source files found"
}

# ============================================================================
# SECTION 9: System Detection
# ============================================================================

detect_username() {
    DETECTED_USERNAME=$(whoami)
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
    HYPR_CONFIG_DIR=$(normalize_path "$HOME/.config/hypr")
    DETECTED_EXECS_FILES=()

    [[ -d "$HYPR_CONFIG_DIR" ]] || return

    # Find all execs*.conf files
    while IFS= read -r -d '' file; do
        DETECTED_EXECS_FILES+=("$file")
    done < <(find "$HYPR_CONFIG_DIR" -name "execs*.conf" -print0 2>/dev/null | sort -z)
}

# ============================================================================
# SECTION 10: Present Detection Results
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

# Classify detected GPUs and display them
# Sets: GPU_NVIDIA_FOUND, GPU_AMD_FOUND, GPU_INTEL_FOUND, GPU_TYPE_COUNT
GPU_NVIDIA_FOUND=false
GPU_AMD_FOUND=false
GPU_INTEL_FOUND=false
GPU_TYPE_COUNT=0
classify_detected_gpus() {
    GPU_NVIDIA_FOUND=false
    GPU_AMD_FOUND=false
    GPU_INTEL_FOUND=false
    GPU_TYPE_COUNT=0

    for gpu in "${DETECTED_GPUS[@]}"; do
        local card="${gpu%%:*}"
        local driver="${gpu##*:}"
        echo "    • $card: $driver"

        case "$driver" in
            nvidia) GPU_NVIDIA_FOUND=true ;;
            amdgpu) GPU_AMD_FOUND=true ;;
            i915)   GPU_INTEL_FOUND=true ;;
        esac
    done

    # Count GPU types found (|| true prevents set -e exit when boolean is false)
    $GPU_NVIDIA_FOUND && ((++GPU_TYPE_COUNT)) || true
    $GPU_AMD_FOUND && ((++GPU_TYPE_COUNT)) || true
    $GPU_INTEL_FOUND && ((++GPU_TYPE_COUNT)) || true
}

# Prompt user to select primary GPU when multiple types detected
# Sets: DETECTED_GPU_TYPE
select_primary_gpu() {
    echo "  Multiple GPU types detected. Which is your primary GPU?"
    echo ""
    local options=() i=1
    $GPU_NVIDIA_FOUND && { options+=("nvidia"); echo "    $i) NVIDIA"; ((i++)); }
    $GPU_AMD_FOUND && { options+=("amd"); echo "    $i) AMD"; ((i++)); }
    $GPU_INTEL_FOUND && { options+=("intel"); echo "    $i) Intel"; ((i++)); }
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
        # Single GPU type - auto-select
        $GPU_NVIDIA_FOUND && DETECTED_GPU_TYPE="nvidia"
        $GPU_AMD_FOUND && DETECTED_GPU_TYPE="amd"
        $GPU_INTEL_FOUND && DETECTED_GPU_TYPE="intel"
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
}

show_detection_summary() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo -e "  ${BOLD}SYSTEM DETECTION SUMMARY${NC}"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "  Username:     $DETECTED_USERNAME"
    echo "  GPU type:     $DETECTED_GPU_TYPE"
    echo "  DRM path:     $DETECTED_DRM_PATH"
    echo "  Config dir:   $HYPR_CONFIG_DIR"
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    if ! ask_yes "Proceed with these settings?"; then
        info "Installation cancelled"
        exit 0
    fi
}

# ============================================================================
# SECTION 11: Installation Functions
# ============================================================================

install_launcher_script() {
    local dest_dir
    dest_dir=$(dirname "$LAUNCHER_DEST")

    if dry_run_preview "Would create: $LAUNCHER_DEST"; then
        return 0
    fi

    mkdir -p "$dest_dir" || { error "Failed to create directory: $dest_dir"; return 1; }

    # Copy the base script
    cp "$LAUNCHER_SRC" "$LAUNCHER_DEST" || { error "Failed to copy launcher script"; return 1; }

    # Uncomment the appropriate GPU section based on detection
    case "$DETECTED_GPU_TYPE" in
        nvidia)
            # Uncomment NVIDIA lines
            sed -i 's/^# set -gx LIBVA_DRIVER_NAME nvidia/set -gx LIBVA_DRIVER_NAME nvidia/' "$LAUNCHER_DEST"
            sed -i 's/^# set -gx __GLX_VENDOR_LIBRARY_NAME nvidia/set -gx __GLX_VENDOR_LIBRARY_NAME nvidia/' "$LAUNCHER_DEST"
            sed -i 's/^# set -gx NVD_BACKEND direct/set -gx NVD_BACKEND direct/' "$LAUNCHER_DEST"
            ;;
        amd)
            # Uncomment AMD line
            sed -i 's/^# set -gx LIBVA_DRIVER_NAME radeonsi/set -gx LIBVA_DRIVER_NAME radeonsi/' "$LAUNCHER_DEST"
            ;;
        intel)
            # Uncomment Intel line
            sed -i 's/^# set -gx LIBVA_DRIVER_NAME iHD/set -gx LIBVA_DRIVER_NAME iHD/' "$LAUNCHER_DEST"
            ;;
        auto|*)
            # Leave all commented - user must configure manually
            warn "GPU type 'auto' - you'll need to uncomment the appropriate GPU section in the script"
            ;;
    esac

    # If specific DRM path was chosen, add it to the script
    if [[ "$DETECTED_DRM_PATH" != "auto" ]]; then
        # Escape path for sed (handle backslashes and ampersands)
        local escaped_drm_path="${DETECTED_DRM_PATH//\\/\\\\}"
        escaped_drm_path="${escaped_drm_path//&/\\&}"

        # Add HYPR_DRM_PATH after the shebang
        sed -i "2i\\
# DRM path set by installer\\
set -gx HYPR_DRM_PATH \"$escaped_drm_path\"\\
" "$LAUNCHER_DEST"
    fi

    chmod +x "$LAUNCHER_DEST" || { error "Failed to make script executable"; return 1; }
    success "Launcher script installed: $LAUNCHER_DEST"
}

install_fish_hook() {
    local dest_dir
    dest_dir=$(dirname "$FISH_HOOK_DEST")

    if dry_run_preview "Would create: $FISH_HOOK_DEST"; then
        return 0
    fi

    mkdir -p "$dest_dir" || { error "Failed to create directory: $dest_dir"; return 1; }
    cp "$FISH_HOOK_SRC" "$FISH_HOOK_DEST" || { error "Failed to copy fish hook"; return 1; }
    success "Fish hook installed: $FISH_HOOK_DEST"
}

show_execs_instructions() {
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

    if [[ -n "${EDITOR:-}" ]] && ask "Open your config in \$EDITOR ($EDITOR)?"; then
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
# SECTION 12: System-Level Installation (Sudo)
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

    cat << EOF | sudo tee "$SYSTEMD_OVERRIDE_FILE" > /dev/null || { error "Failed to write autologin config"; return 1; }
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty -o "-p -f -- \\u" --noclear --autologin $DETECTED_USERNAME %I \$TERM
EOF

    sudo systemctl daemon-reload || { error "Failed to reload systemd daemon"; return 1; }
    success "Autologin configured for: $DETECTED_USERNAME"
}

# ============================================================================
# SECTION 13: Staged Testing
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
            *)
                info "Exiting - SDDM not modified"
                echo ""
                echo "  User-level components are installed."
                echo "  Fix issues and re-run installer when ready."
                exit 0
                ;;
        esac
    done
}

# ============================================================================
# SECTION 14: SDDM Cutover
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
        sudo systemctl disable sddm || { error "Failed to disable SDDM"; return 1; }
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
        sudo reboot
    else
        info "Remember to reboot to apply changes"
    fi
}

# ============================================================================
# SECTION 15: Uninstall Functions
# ============================================================================

uninstall() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo -e "  ${BOLD}UNINSTALL hypr-login${NC}"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    if ! ask_yes "Remove all hypr-login components?"; then
        info "Uninstall cancelled"
        exit 0
    fi

    echo ""

    # Remove user-level components
    remove_if_exists "$LAUNCHER_DEST" "Launcher script"
    remove_if_exists "$FISH_HOOK_DEST" "Fish hook"

    # Remove systemd override (requires sudo)
    if [[ -f "$SYSTEMD_OVERRIDE_FILE" ]]; then
        if ask_yes "Remove systemd autologin override? (requires sudo)"; then
            if $DRY_RUN; then
                echo "$(dry_run_prefix)Would remove: $SYSTEMD_OVERRIDE_FILE"
            else
                sudo rm -f "$SYSTEMD_OVERRIDE_FILE"
                sudo systemctl daemon-reload
                success "Removed systemd override"
            fi
        fi
    fi

    echo ""
    echo -e "  ${YELLOW}Remaining manual steps:${NC}"
    echo "    1. Remove 'exec-once = hyprlock' from your execs.conf"
    echo -e "    2. Re-enable SDDM: ${CYAN}sudo systemctl enable sddm${NC}"
    echo "    3. Reboot"
    echo ""

    if ask_yes "Enable SDDM now?"; then
        if $DRY_RUN; then
            echo "$(dry_run_prefix)Would run: sudo systemctl enable sddm"
        else
            sudo systemctl enable sddm
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
# SECTION 16: Update Mode
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
# SECTION 17: Main Installation
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

    # Present and confirm
    present_username
    present_gpu_options
    present_display_options
    present_config_info
    show_detection_summary

    # Phase 2: User-level installation
    echo ""
    info "Installing user-level components..."
    install_launcher_script
    install_fish_hook

    # Show execs.conf instructions (never auto-modify)
    show_execs_instructions

    # Phase 3: System-level installation
    if request_sudo; then
        create_autologin_override

        # Phase 4: Staged testing
        setup_tty2_testing
        guide_tty2_test
        confirm_test_passed

        # Phase 5: SDDM cutover
        confirm_sddm_disable
        disable_sddm
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
# SECTION 18: Argument Parsing
# ============================================================================

for arg in "$@"; do
    case "$arg" in
        -h|--help)      show_help ;;
        -n|--dry-run)   DRY_RUN=true ;;
        -u|--uninstall) UNINSTALL=true ;;
        -d|--update)    UPDATE_MODE=true ;;
        --skip-test)    SKIP_TEST=true ;;
        *)
            error "Unknown option: $arg"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# ============================================================================
# SECTION 19: Entry Point
# ============================================================================

if $UNINSTALL; then
    uninstall
elif $UPDATE_MODE; then
    update
else
    install
fi
