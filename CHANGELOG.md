# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **BREAKING**: Now requires Hyprland 0.53+ (uses `start-hyprland` watchdog)
- Launcher script (`hyprland-tty.fish`) now calls `start-hyprland` instead of `Hyprland` directly
- Simplified autostart hook (`hyprland-autostart.fish`) - crash recovery now handled by `start-hyprland`

### Added

- Version check in installer that blocks installation on Hyprland <0.53
- Interactive installer (`setup.sh`) with detect + present options pattern
- UWSM session method support alongside exec-once method
- hyprlock-wrapper extras for boot-aware hyprlock configurations
- Smart GPU detection with data-driven approach and discrete GPU preference
- BATS test suite for installer functions
- Integration tests for user journey paths
- Comprehensive SECURITY.md documentation

### Changed

- Rename installer to `setup.sh` with improved ANSI color formatting
- Reorganize project structure for better maintainability
- Match GPU selection order to detection order for consistency
- Improve code quality with function extraction and documentation
- Extract phase functions from install() and update() for testability
- Add configurable timeouts for improved testability

### Fixed

- Critical reliability improvements for trap consolidation and input handling
- Config validation and error state handling
- Security hardening and UX improvements across installer
- Error handling gaps from comprehensive code analysis
- Bash best practices compliance and large function refactoring
- GPU detection reliability and cleanup robustness
- Variable quoting in wait_for_resource calls
- VT switching range corrected to F1-F6
