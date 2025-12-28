#!/usr/bin/env bats
#
# Tests for setup.sh
# Run with: bats tests/setup.bats
#
# Requirements: bats-core (sudo pacman -S bats)

# Load setup.sh functions without executing main
setup() {
    # Get the directory where the test file lives
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_DIR="$(dirname "$TEST_DIR")"

    # Source the script in test mode
    source "$PROJECT_DIR/setup.sh" --source-only

    # Disable strict mode AFTER sourcing (script's set -eu re-enables it)
    # BATS has its own error handling; set -u breaks associative array access
    set +eu
}

# ============================================================================
# classify_detected_gpus tests
# ============================================================================

@test "classify_detected_gpus: AMD before NVIDIA preserves detection order" {
    DETECTED_GPUS=("card0:amdgpu" "card1:nvidia")
    classify_detected_gpus >/dev/null

    [[ "${GPU_TYPES_IN_ORDER[0]}" == "amd:AMD" ]]
    [[ "${GPU_TYPES_IN_ORDER[1]}" == "nvidia:NVIDIA" ]]
    [[ "$GPU_TYPE_COUNT" -eq 2 ]]
}

@test "classify_detected_gpus: NVIDIA before AMD preserves detection order" {
    DETECTED_GPUS=("card0:nvidia" "card1:amdgpu")
    classify_detected_gpus >/dev/null

    [[ "${GPU_TYPES_IN_ORDER[0]}" == "nvidia:NVIDIA" ]]
    [[ "${GPU_TYPES_IN_ORDER[1]}" == "amd:AMD" ]]
    [[ "$GPU_TYPE_COUNT" -eq 2 ]]
}

@test "classify_detected_gpus: Intel GPU detected correctly" {
    DETECTED_GPUS=("card0:i915")
    classify_detected_gpus >/dev/null

    [[ "${GPU_TYPES_IN_ORDER[0]}" == "intel:Intel" ]]
    [[ "$GPU_TYPE_COUNT" -eq 1 ]]
}

@test "classify_detected_gpus: all three GPU types in order" {
    DETECTED_GPUS=("card0:i915" "card1:amdgpu" "card2:nvidia")
    classify_detected_gpus >/dev/null

    [[ "${GPU_TYPES_IN_ORDER[0]}" == "intel:Intel" ]]
    [[ "${GPU_TYPES_IN_ORDER[1]}" == "amd:AMD" ]]
    [[ "${GPU_TYPES_IN_ORDER[2]}" == "nvidia:NVIDIA" ]]
    [[ "$GPU_TYPE_COUNT" -eq 3 ]]
}

@test "classify_detected_gpus: duplicate drivers counted only once" {
    DETECTED_GPUS=("card0:amdgpu" "card1:amdgpu")
    classify_detected_gpus >/dev/null

    [[ "$GPU_TYPE_COUNT" -eq 1 ]]
    [[ "${#GPU_TYPES_IN_ORDER[@]}" -eq 1 ]]
    [[ "${GPU_TYPES_IN_ORDER[0]}" == "amd:AMD" ]]
}

@test "classify_detected_gpus: unknown driver ignored" {
    DETECTED_GPUS=("card0:some_unknown_driver")
    classify_detected_gpus >/dev/null

    [[ "$GPU_TYPE_COUNT" -eq 0 ]]
    [[ "${#GPU_TYPES_IN_ORDER[@]}" -eq 0 ]]
}

@test "classify_detected_gpus: mixed known and unknown drivers" {
    DETECTED_GPUS=("card0:virtio_gpu" "card1:nvidia" "card2:unknown")
    classify_detected_gpus >/dev/null

    [[ "$GPU_TYPE_COUNT" -eq 1 ]]
    [[ "${GPU_TYPES_IN_ORDER[0]}" == "nvidia:NVIDIA" ]]
}

@test "classify_detected_gpus: empty input produces empty output" {
    DETECTED_GPUS=()
    classify_detected_gpus >/dev/null

    [[ "$GPU_TYPE_COUNT" -eq 0 ]]
    [[ "${#GPU_TYPES_IN_ORDER[@]}" -eq 0 ]]
}

# ============================================================================
# normalize_path tests
# ============================================================================

@test "normalize_path: expands tilde to HOME" {
    result=$(normalize_path "~/foo")
    [[ "$result" == "$HOME/foo" ]]
}

@test "normalize_path: expands standalone tilde" {
    result=$(normalize_path "~")
    [[ "$result" == "$HOME" ]]
}

@test "normalize_path: strips file:// prefix" {
    result=$(normalize_path "file:///home/user/file.txt")
    [[ "$result" == "/home/user/file.txt" ]]
}

@test "normalize_path: absolute path unchanged" {
    result=$(normalize_path "/usr/bin/bash")
    [[ "$result" == "/usr/bin/bash" ]]
}

@test "normalize_path: removes trailing slash" {
    result=$(normalize_path "/home/user/")
    [[ "$result" == "/home/user" ]]
}

@test "normalize_path: root path stays as /" {
    result=$(normalize_path "/")
    [[ "$result" == "/" ]]
}

@test "normalize_path: resolves parent directory references" {
    result=$(normalize_path "/home/user/../user/file")
    [[ "$result" == "/home/user/file" ]]
}

@test "normalize_path: resolves double slashes" {
    result=$(normalize_path "/home//user///file")
    [[ "$result" == "/home/user/file" ]]
}

# ============================================================================
# GPU_DRIVER_MAP tests
# ============================================================================

@test "GPU_DRIVER_MAP: nvidia mapping exists" {
    [[ "${GPU_DRIVER_MAP[nvidia]}" == "nvidia:NVIDIA" ]]
}

@test "GPU_DRIVER_MAP: amdgpu mapping exists" {
    [[ "${GPU_DRIVER_MAP[amdgpu]}" == "amd:AMD" ]]
}

@test "GPU_DRIVER_MAP: i915 mapping exists" {
    [[ "${GPU_DRIVER_MAP[i915]}" == "intel:Intel" ]]
}

# ============================================================================
# Helper function tests
# ============================================================================

@test "is_sddm_enabled: returns exit code (no crash)" {
    # Just verify it runs without error - actual result depends on system
    run is_sddm_enabled
    # Should return 0 or 1, not crash
    [[ "$status" -eq 0 || "$status" -eq 1 ]]
}

# ============================================================================
# load_install_config tests
# ============================================================================

@test "load_install_config: returns 1 for missing file" {
    CONFIG_FILE="/nonexistent/path/config.conf"
    run load_install_config
    [[ "$status" -eq 1 ]]
}

@test "load_install_config: returns 1 for empty file" {
    local temp_config
    temp_config=$(mktemp)
    CONFIG_FILE="$temp_config"

    run load_install_config
    [[ "$status" -eq 1 ]]

    rm -f "$temp_config"
}

@test "load_install_config: loads valid exec-once config" {
    local temp_config
    temp_config=$(mktemp)
    cat > "$temp_config" << 'EOF'
SESSION_METHOD=exec-once
GPU_TYPE=nvidia
DRM_PATH=auto
EOF
    CONFIG_FILE="$temp_config"
    SESSION_METHOD=""
    DETECTED_GPU_TYPE=""
    DETECTED_DRM_PATH=""

    run load_install_config
    # Re-source to get the values (run creates subshell)
    load_install_config

    [[ "$SESSION_METHOD" == "exec-once" ]]
    [[ "$DETECTED_GPU_TYPE" == "nvidia" ]]
    [[ "$DETECTED_DRM_PATH" == "auto" ]]

    rm -f "$temp_config"
}

@test "load_install_config: loads valid uwsm config" {
    local temp_config
    temp_config=$(mktemp)
    cat > "$temp_config" << 'EOF'
SESSION_METHOD=uwsm
GPU_TYPE=amd
DRM_PATH=auto
EOF
    CONFIG_FILE="$temp_config"
    SESSION_METHOD=""
    DETECTED_GPU_TYPE=""
    DETECTED_DRM_PATH=""

    load_install_config

    [[ "$SESSION_METHOD" == "uwsm" ]]
    [[ "$DETECTED_GPU_TYPE" == "amd" ]]

    rm -f "$temp_config"
}

@test "load_install_config: rejects invalid SESSION_METHOD" {
    local temp_config
    temp_config=$(mktemp)
    cat > "$temp_config" << 'EOF'
SESSION_METHOD=invalid
GPU_TYPE=nvidia
DRM_PATH=auto
EOF
    CONFIG_FILE="$temp_config"
    SESSION_METHOD=""

    load_install_config 2>/dev/null

    # SESSION_METHOD should remain empty (invalid value rejected)
    [[ -z "$SESSION_METHOD" ]]

    rm -f "$temp_config"
}

@test "load_install_config: validates DRM_PATH format" {
    local temp_config
    temp_config=$(mktemp)
    cat > "$temp_config" << 'EOF'
SESSION_METHOD=exec-once
GPU_TYPE=nvidia
DRM_PATH=/run/udev/data/+drm:card0-HDMI-A-1
EOF
    CONFIG_FILE="$temp_config"
    DETECTED_DRM_PATH=""

    load_install_config

    [[ "$DETECTED_DRM_PATH" == "/run/udev/data/+drm:card0-HDMI-A-1" ]]

    rm -f "$temp_config"
}

# ============================================================================
# Timeout configuration tests
# ============================================================================

@test "SYSTEMCTL_DEFAULT_TIMEOUT: uses default value" {
    [[ "$SYSTEMCTL_DEFAULT_TIMEOUT" == "5" ]] || [[ -n "$HYPR_LOGIN_SYSTEMCTL_TIMEOUT" ]]
}

@test "SYSTEMCTL_VERIFY_TIMEOUT: uses default value" {
    [[ "$SYSTEMCTL_VERIFY_TIMEOUT" == "3" ]] || [[ -n "$HYPR_LOGIN_VERIFY_TIMEOUT" ]]
}

# ============================================================================
# validate_file tests
# ============================================================================

@test "validate_file: returns 0 for existing readable file" {
    local temp_file
    temp_file=$(mktemp)
    echo "content" > "$temp_file"

    run validate_file "$temp_file" "test file"
    [[ "$status" -eq 0 ]]

    rm -f "$temp_file"
}

@test "validate_file: returns 1 for missing file" {
    run validate_file "/nonexistent/path/file.txt" "test file"
    [[ "$status" -eq 1 ]]
}

@test "validate_file: returns 1 for empty file" {
    local temp_file
    temp_file=$(mktemp)
    # File exists but is empty

    run validate_file "$temp_file" "test file"
    [[ "$status" -eq 1 ]]

    rm -f "$temp_file"
}

@test "validate_file: uses default description if not provided" {
    run validate_file "/nonexistent/path/file.txt"
    [[ "$status" -eq 1 ]]
    # Should not crash with missing second arg
}

# ============================================================================
# collect_gpu_metadata tests
# ============================================================================

@test "collect_gpu_metadata: counts driver occurrences" {
    DETECTED_GPUS=("card0:nvidia" "card1:nvidia" "card2:amdgpu")
    collect_gpu_metadata

    [[ "${_GPU_DRIVER_COUNT[nvidia]}" -eq 2 ]]
    [[ "${_GPU_DRIVER_COUNT[amdgpu]}" -eq 1 ]]
}

@test "collect_gpu_metadata: identifies unknown drivers" {
    DETECTED_GPUS=("card0:nvidia" "card1:virtio_gpu")
    collect_gpu_metadata

    [[ "${#_GPU_UNKNOWN_DRIVERS[@]}" -eq 1 ]]
    [[ "${_GPU_UNKNOWN_DRIVERS[0]}" == "virtio_gpu" ]]
}

@test "collect_gpu_metadata: deduplicates unknown drivers" {
    DETECTED_GPUS=("card0:virtio_gpu" "card1:virtio_gpu")
    collect_gpu_metadata

    [[ "${#_GPU_UNKNOWN_DRIVERS[@]}" -eq 1 ]]
}

@test "collect_gpu_metadata: empty input produces empty output" {
    DETECTED_GPUS=()
    collect_gpu_metadata

    [[ "${#_GPU_UNKNOWN_DRIVERS[@]}" -eq 0 ]]
    [[ "${#_GPU_DRIVER_COUNT[@]}" -eq 0 ]]
}

# ============================================================================
# build_gpu_types_list tests
# ============================================================================

@test "build_gpu_types_list: preserves detection order" {
    DETECTED_GPUS=("card0:i915" "card1:amdgpu" "card2:nvidia")
    build_gpu_types_list

    [[ "${GPU_TYPES_IN_ORDER[0]}" == "intel:Intel" ]]
    [[ "${GPU_TYPES_IN_ORDER[1]}" == "amd:AMD" ]]
    [[ "${GPU_TYPES_IN_ORDER[2]}" == "nvidia:NVIDIA" ]]
}

@test "build_gpu_types_list: deduplicates drivers" {
    DETECTED_GPUS=("card0:nvidia" "card1:nvidia")
    build_gpu_types_list

    [[ "$GPU_TYPE_COUNT" -eq 1 ]]
    [[ "${#GPU_TYPES_IN_ORDER[@]}" -eq 1 ]]
}

@test "build_gpu_types_list: ignores unknown drivers" {
    DETECTED_GPUS=("card0:virtio_gpu" "card1:nvidia")
    build_gpu_types_list

    [[ "$GPU_TYPE_COUNT" -eq 1 ]]
    [[ "${GPU_TYPES_IN_ORDER[0]}" == "nvidia:NVIDIA" ]]
}

# ============================================================================
# apply_gpu_variable tests
# ============================================================================

@test "apply_gpu_variable: uncomments matching pattern" {
    local temp_file
    temp_file=$(mktemp)
    echo "# set -gx LIBVA_DRIVER_NAME nvidia" > "$temp_file"
    echo "# set -gx OTHER_VAR value" >> "$temp_file"

    run apply_gpu_variable "$temp_file" "LIBVA_DRIVER_NAME" "nvidia"
    [[ "$status" -eq 0 ]]

    # Verify pattern was uncommented
    grep -q "^set -gx LIBVA_DRIVER_NAME nvidia$" "$temp_file"

    rm -f "$temp_file"
}

@test "apply_gpu_variable: fails if pattern not found" {
    local temp_file
    temp_file=$(mktemp)
    echo "set -gx SOME_OTHER_VAR value" > "$temp_file"

    run apply_gpu_variable "$temp_file" "NONEXISTENT_VAR" "value"
    [[ "$status" -eq 1 ]]

    rm -f "$temp_file"
}

@test "apply_gpu_variable: preserves other lines unchanged" {
    local temp_file
    temp_file=$(mktemp)
    echo "#!/usr/bin/fish" > "$temp_file"
    echo "# set -gx LIBVA_DRIVER_NAME nvidia" >> "$temp_file"
    echo "set -gx EXISTING_VAR value" >> "$temp_file"

    apply_gpu_variable "$temp_file" "LIBVA_DRIVER_NAME" "nvidia"

    # First line unchanged
    head -1 "$temp_file" | grep -q "#!/usr/bin/fish"
    # Third line unchanged
    tail -1 "$temp_file" | grep -q "set -gx EXISTING_VAR value"

    rm -f "$temp_file"
}

# ============================================================================
# apply_drm_path_config tests
# ============================================================================

@test "apply_drm_path_config: skips on auto" {
    local temp_file
    temp_file=$(mktemp)
    echo "#!/usr/bin/fish" > "$temp_file"
    DETECTED_DRM_PATH="auto"

    run apply_drm_path_config "$temp_file"
    [[ "$status" -eq 0 ]]

    # File should be unchanged (still 1 line)
    [[ $(wc -l < "$temp_file") -eq 1 ]]

    rm -f "$temp_file"
}

@test "apply_drm_path_config: inserts valid DRM path" {
    local temp_file
    temp_file=$(mktemp)
    echo "#!/usr/bin/fish" > "$temp_file"
    echo "# rest of script" >> "$temp_file"
    DETECTED_DRM_PATH="/run/udev/data/+drm:card0-HDMI-A-1"

    run apply_drm_path_config "$temp_file"
    [[ "$status" -eq 0 ]]

    # Should have HYPR_DRM_PATH in file
    grep -q "HYPR_DRM_PATH" "$temp_file"

    rm -f "$temp_file"
}

@test "apply_drm_path_config: rejects invalid DRM path format" {
    local temp_file
    temp_file=$(mktemp)
    echo "#!/usr/bin/fish" > "$temp_file"
    DETECTED_DRM_PATH="/some/invalid/path"

    run apply_drm_path_config "$temp_file"
    [[ "$status" -eq 1 ]]

    rm -f "$temp_file"
}

# ============================================================================
# save_install_config tests
# ============================================================================

@test "save_install_config: creates config file with correct values" {
    local temp_dir
    temp_dir=$(mktemp -d)
    CONFIG_DIR="$temp_dir"
    CONFIG_FILE="$temp_dir/install.conf"
    SESSION_METHOD="exec-once"
    DETECTED_GPU_TYPE="nvidia"
    DETECTED_DRM_PATH="auto"

    run save_install_config
    [[ "$status" -eq 0 ]]

    # Verify file exists and contains expected values
    [[ -f "$CONFIG_FILE" ]]
    grep -q "SESSION_METHOD=exec-once" "$CONFIG_FILE"
    grep -q "GPU_TYPE=nvidia" "$CONFIG_FILE"
    grep -q "DRM_PATH=auto" "$CONFIG_FILE"

    rm -rf "$temp_dir"
}

@test "save_install_config: sets restrictive permissions" {
    local temp_dir
    temp_dir=$(mktemp -d)
    CONFIG_DIR="$temp_dir"
    CONFIG_FILE="$temp_dir/install.conf"
    SESSION_METHOD="uwsm"
    DETECTED_GPU_TYPE="amd"
    DETECTED_DRM_PATH="auto"

    save_install_config

    # File should have 600 permissions
    local perms
    perms=$(stat -c %a "$CONFIG_FILE")
    [[ "$perms" == "600" ]]

    rm -rf "$temp_dir"
}

@test "save_install_config: creates config directory if missing" {
    local temp_dir
    temp_dir=$(mktemp -d)
    CONFIG_DIR="$temp_dir/nested/subdir"
    CONFIG_FILE="$CONFIG_DIR/install.conf"
    SESSION_METHOD="exec-once"
    DETECTED_GPU_TYPE="intel"
    DETECTED_DRM_PATH="auto"

    run save_install_config
    [[ "$status" -eq 0 ]]
    [[ -d "$CONFIG_DIR" ]]

    rm -rf "$temp_dir"
}
