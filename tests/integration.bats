#!/usr/bin/env bats
#
# Integration tests for setup.sh user journeys
# Run with: bats tests/integration.bats
#
# These tests verify complete user flows by mocking interactive prompts.
# Each test simulates a different path through the installer.
#
# SAFETY: All system-modifying commands (sudo, systemctl) are mocked to
# prevent accidental changes. Tests run in isolated temp directories.

# ============================================================================
# Test Harness Setup
# ============================================================================

# Mock response queue - tests push responses, mocked functions pop them
MOCK_RESPONSES=()
MOCK_RESPONSE_INDEX=0

# Track function calls for verification
CALL_LOG=()

# Push a response to the mock queue
mock_push() {
    MOCK_RESPONSES+=("$1")
}

# Pop a response from the mock queue
mock_pop() {
    if [[ $MOCK_RESPONSE_INDEX -lt ${#MOCK_RESPONSES[@]} ]]; then
        local response="${MOCK_RESPONSES[$MOCK_RESPONSE_INDEX]}"
        ((MOCK_RESPONSE_INDEX++))
        echo "$response"
    else
        echo ""  # Default empty response
    fi
}

# Log a function call
log_call() {
    CALL_LOG+=("$1")
}

# Check if a function was called
was_called() {
    local func="$1"
    for call in "${CALL_LOG[@]}"; do
        [[ "$call" == "$func" ]] && return 0
    done
    return 1
}

# Reset mock state between tests
reset_mocks() {
    MOCK_RESPONSES=()
    MOCK_RESPONSE_INDEX=0
    CALL_LOG=()
}

# Create isolated test environment
setup() {
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_DIR="$(dirname "$TEST_DIR")"

    # Create temp directories for test isolation
    TEST_TEMP=$(mktemp -d)
    TEST_HOME="$TEST_TEMP/home"
    TEST_CONFIG="$TEST_HOME/.config"
    mkdir -p "$TEST_CONFIG/hypr/scripts"
    mkdir -p "$TEST_CONFIG/fish/conf.d"
    mkdir -p "$TEST_CONFIG/systemd/user"
    mkdir -p "$TEST_CONFIG/hypr-login"

    # Source the script in test mode
    source "$PROJECT_DIR/setup.sh" --source-only
    set +eu

    # Override paths to use test directories
    HOME="$TEST_HOME"
    LAUNCHER_DEST="$TEST_CONFIG/hypr/scripts/hyprland-tty.fish"
    FISH_HOOK_DEST="$TEST_CONFIG/fish/conf.d/hyprland-autostart.fish"
    CONFIG_DIR="$TEST_CONFIG/hypr-login"
    CONFIG_FILE="$CONFIG_DIR/install.conf"
    HYPRLOCK_SERVICE_DEST="$TEST_CONFIG/systemd/user/hyprlock.service"
    HYPR_CONFIG_DIR="$TEST_CONFIG/hypr"

    # CRITICAL: Override source paths to use test copies (prevents corrupting real source!)
    TEST_SRC_DIR="$TEST_TEMP/src"
    mkdir -p "$TEST_SRC_DIR/scripts/fish"
    mkdir -p "$TEST_SRC_DIR/configs/systemd/user"
    echo "#!/usr/bin/fish" > "$TEST_SRC_DIR/scripts/fish/hyprland-tty.fish"
    echo "# test hook" > "$TEST_SRC_DIR/scripts/fish/hyprland-autostart.fish"
    echo "[Service]" > "$TEST_SRC_DIR/configs/systemd/user/hyprlock.service"
    SCRIPT_DIR="$TEST_SRC_DIR"
    LAUNCHER_SRC="$TEST_SRC_DIR/scripts/fish/hyprland-tty.fish"
    FISH_HOOK_SRC="$TEST_SRC_DIR/scripts/fish/hyprland-autostart.fish"
    HYPRLOCK_SERVICE_SRC="$TEST_SRC_DIR/configs/systemd/user/hyprlock.service"

    # Override interactive functions with mocks
    ask() {
        log_call "ask:$1"
        local response
        response=$(mock_pop)
        [[ "$response" =~ ^[Yy]$ ]]
    }

    ask_yes() {
        log_call "ask_yes:$1"
        local response
        response=$(mock_pop)
        [[ ! "$response" =~ ^[Nn]$ ]]
    }

    ask_critical() {
        log_call "ask_critical:$1"
        local response
        response=$(mock_pop)
        [[ "$response" == "$2" ]]
    }

    # Mock systemctl to avoid actual system calls
    systemctl_safe() {
        log_call "systemctl_safe:$*"
        return 0  # Success by default
    }

    # Mock sudo to avoid actual privilege escalation
    # CRITICAL: Do NOT execute commands - just log them!
    sudo() {
        log_call "sudo:$*"
        # Return success without executing (prevents accidental system changes)
        return 0
    }

    reset_mocks
}

teardown() {
    rm -rf "$TEST_TEMP" 2>/dev/null || true
}

# ============================================================================
# Install Flow Tests
# ============================================================================

@test "install: declines at welcome prompt exits cleanly" {
    mock_push "n"  # Continue with installation? -> No

    run install_show_welcome

    [[ "$status" -eq 0 ]]
    was_called "ask:Continue with installation?"
}

@test "install: accepts welcome, runs preflight checks" {
    mock_push "y"  # Continue with installation? -> Yes

    # Source files are now created in setup() in TEST_SRC_DIR
    run install_show_welcome
    [[ "$status" -eq 0 ]]

    # Preflight should work with our test source files
    run validate_source_files
    [[ "$status" -eq 0 ]]
}

@test "install: already installed offers update redirect" {
    # Simulate installed state
    echo "#!/usr/bin/fish" > "$LAUNCHER_DEST"
    echo "# hook" > "$FISH_HOOK_DEST"
    mkdir -p "$(dirname "$SYSTEMD_OVERRIDE_DEST")"
    echo "[Service]" > "$TEST_TEMP/autologin.conf"  # Can't write to /etc in test
    echo "SESSION_METHOD=exec-once" > "$CONFIG_FILE"
    echo "GPU_TYPE=nvidia" >> "$CONFIG_FILE"
    echo "DRM_PATH=auto" >> "$CONFIG_FILE"

    [[ $(is_launcher_installed && echo "yes") == "yes" ]]
    [[ $(is_fish_hook_installed && echo "yes") == "yes" ]]
}

@test "install: present_username accepts default" {
    DETECTED_USERNAME="testuser"
    mock_push "y"  # Use this username? -> Yes

    # Mock id command to validate user
    id() { return 0; }

    run present_username

    [[ "$status" -eq 0 ]]
    [[ "$DETECTED_USERNAME" == "testuser" ]]
}

@test "install: present_username allows override" {
    DETECTED_USERNAME="olduser"
    mock_push "n"        # Use this username? -> No
    mock_push "newuser"  # Enter username

    # Mock id command
    id() { return 0; }

    # Override read to use mock
    read() {
        if [[ "$1" == "-r" ]]; then
            REPLY=$(mock_pop)
            eval "${@: -1}=\$REPLY"  # Set the variable
        fi
    }

    present_username

    [[ "$DETECTED_USERNAME" == "newuser" ]]
}

# ============================================================================
# Session Method Detection Tests
# ============================================================================

@test "session method: UWSM active, user accepts" {
    # Mock UWSM as active
    check_uwsm_status() { echo "active"; }

    mock_push "y"  # Use UWSM method? -> Yes

    run try_auto_detect_session_method

    [[ "$status" -eq 0 ]]
    [[ "$SESSION_METHOD" == "uwsm" ]]
}

@test "session method: UWSM active, user declines falls to manual" {
    check_uwsm_status() { echo "active"; }

    mock_push "n"  # Use UWSM method? -> No

    run try_auto_detect_session_method

    [[ "$status" -eq 1 ]]  # Returns 1 to trigger manual selection
}

@test "session method: UWSM not found, user accepts exec-once" {
    check_uwsm_status() { echo "not-found"; }

    mock_push "y"  # Use exec-once method? -> Yes

    run try_auto_detect_session_method

    [[ "$status" -eq 0 ]]
    [[ "$SESSION_METHOD" == "exec-once" ]]
}

@test "session method: manual selection chooses exec-once" {
    mock_push "1"  # Choose option 1 (exec-once)

    # Override read for menu selection
    read() {
        if [[ "$1" == "-r" ]]; then
            REPLY=$(mock_pop)
            eval "${@: -1}=\$REPLY"
        fi
    }

    select_session_method_manual

    [[ "$SESSION_METHOD" == "exec-once" ]]
}

@test "session method: manual selection chooses UWSM" {
    mock_push "2"  # Choose option 2 (uwsm)

    read() {
        if [[ "$1" == "-r" ]]; then
            REPLY=$(mock_pop)
            eval "${@: -1}=\$REPLY"
        fi
    }

    select_session_method_manual

    [[ "$SESSION_METHOD" == "uwsm" ]]
}

# ============================================================================
# Detection Summary Tests
# ============================================================================

@test "detection summary: user confirms proceeds" {
    DETECTED_USERNAME="testuser"
    DETECTED_GPU_TYPE="nvidia"
    DETECTED_DRM_PATH="auto"
    HYPR_CONFIG_DIR="/home/test/.config/hypr"
    SESSION_METHOD="exec-once"

    mock_push "y"  # Proceed with these settings? -> Yes

    run present_detection_summary

    [[ "$status" -eq 0 ]]
}

@test "detection summary: user declines exits" {
    DETECTED_USERNAME="testuser"
    DETECTED_GPU_TYPE="nvidia"
    DETECTED_DRM_PATH="auto"
    HYPR_CONFIG_DIR="/home/test/.config/hypr"
    SESSION_METHOD="exec-once"

    mock_push "n"  # Proceed with these settings? -> No

    run present_detection_summary

    [[ "$status" -eq 0 ]]  # Exits cleanly via exit 0
}

# ============================================================================
# Sudo/System Component Tests
# ============================================================================

@test "request_sudo: user declines skips system config" {
    mock_push "n"  # Proceed with sudo operations? -> No

    run request_sudo

    [[ "$status" -eq 1 ]]  # Returns 1 to skip system config
}

@test "request_sudo: user accepts continues" {
    mock_push "y"  # Proceed with sudo operations? -> Yes

    # Mock timeout and sudo -v
    timeout() { return 0; }

    run request_sudo

    [[ "$status" -eq 0 ]]
}

# ============================================================================
# SDDM Cutover Tests
# ============================================================================

@test "confirm_sddm_disable: typing 'yes' proceeds" {
    mock_push "yes"  # Type 'yes' to confirm

    run confirm_sddm_disable

    [[ "$status" -eq 0 ]]
}

@test "confirm_sddm_disable: typing anything else exits" {
    mock_push "no"  # Type something other than 'yes'

    run confirm_sddm_disable

    [[ "$status" -eq 0 ]]  # Exits cleanly
}

# ============================================================================
# Uninstall Flow Tests
# ============================================================================

@test "uninstall: user declines exits" {
    mock_push "n"  # Remove all components? -> No

    run uninstall

    [[ "$status" -eq 0 ]]
}

@test "uninstall: user confirms removes components" {
    # Create files to remove
    echo "#!/usr/bin/fish" > "$LAUNCHER_DEST"
    echo "# hook" > "$FISH_HOOK_DEST"
    echo "SESSION_METHOD=exec-once" > "$CONFIG_FILE"

    mock_push "y"  # Remove all components? -> Yes
    mock_push "n"  # Remove systemd override? -> No (skip sudo)
    mock_push "n"  # Enable SDDM? -> No
    mock_push "n"  # Reboot? -> No

    run uninstall

    [[ "$status" -eq 0 ]]
    [[ ! -f "$LAUNCHER_DEST" ]]
    [[ ! -f "$FISH_HOOK_DEST" ]]
}

# ============================================================================
# Update Flow Tests
# ============================================================================

@test "update: not installed redirects to install" {
    # Ensure nothing is installed
    rm -f "$LAUNCHER_DEST" "$FISH_HOOK_DEST" 2>/dev/null || true

    # This will try to run install, which needs more mocks
    # For now just verify detection works
    run is_launcher_installed
    [[ "$status" -eq 1 ]]

    run is_fish_hook_installed
    [[ "$status" -eq 1 ]]
}

@test "update: loads previous config" {
    echo "SESSION_METHOD=uwsm" > "$CONFIG_FILE"
    echo "GPU_TYPE=amd" >> "$CONFIG_FILE"
    echo "DRM_PATH=auto" >> "$CONFIG_FILE"

    load_install_config

    [[ "$SESSION_METHOD" == "uwsm" ]]
    [[ "$DETECTED_GPU_TYPE" == "amd" ]]
    [[ "$DETECTED_DRM_PATH" == "auto" ]]
}

# ============================================================================
# Troubleshooting Menu Tests
# ============================================================================

@test "troubleshooting: option 4 exits" {
    mock_push "4"  # Exit installer

    read() {
        if [[ "$1" == "-r" ]]; then
            REPLY=$(mock_pop)
            eval "${@: -1}=\$REPLY"
        fi
    }

    run handle_test_troubleshooting

    [[ "$status" -eq 1 ]]  # Returns 1 to exit
}

@test "troubleshooting: option 3 continues (try again)" {
    mock_push "3"  # Try test again

    read() {
        if [[ "$1" == "-r" ]]; then
            REPLY=$(mock_pop)
            eval "${@: -1}=\$REPLY"
        fi
    }

    # Mock guide_tty2_test
    guide_tty2_test() { log_call "guide_tty2_test"; }

    run handle_test_troubleshooting

    [[ "$status" -eq 0 ]]
    was_called "guide_tty2_test"
}

# ============================================================================
# Hybrid Configuration Tests
# ============================================================================

@test "hybrid check: no service installed continues" {
    rm -f "$HYPRLOCK_SERVICE_DEST" 2>/dev/null || true

    run check_hybrid_configuration

    [[ "$status" -eq 0 ]]
}

@test "hybrid check: service exists, user removes it" {
    echo "[Service]" > "$HYPRLOCK_SERVICE_DEST"

    mock_push "1"  # Remove service and continue

    read() {
        if [[ "$1" == "-r" ]]; then
            REPLY=$(mock_pop)
            eval "${@: -1}=\$REPLY"
        fi
    }

    run check_hybrid_configuration

    [[ "$status" -eq 0 ]]
    was_called "systemctl_safe:--user --quiet disable hyprlock.service"
}

@test "hybrid check: service exists, user skips config" {
    echo "[Service]" > "$HYPRLOCK_SERVICE_DEST"

    mock_push "2"  # Skip configuration

    read() {
        if [[ "$1" == "-r" ]]; then
            REPLY=$(mock_pop)
            eval "${@: -1}=\$REPLY"
        fi
    }

    run check_hybrid_configuration

    [[ "$status" -eq 1 ]]  # Returns 1 to skip
}
