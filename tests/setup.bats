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
