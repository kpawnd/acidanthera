#!/bin/bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACID_ROOT="$SCRIPT_DIR"
export ACID_ROOT

# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/scripts/lib/common.sh"
# shellcheck source=scripts/lib/platform_homebrew.sh
source "$SCRIPT_DIR/scripts/lib/platform_homebrew.sh"
# shellcheck source=scripts/lib/apps_cleanup.sh
source "$SCRIPT_DIR/scripts/lib/apps_cleanup.sh"
# shellcheck source=scripts/lib/features.sh
source "$SCRIPT_DIR/scripts/lib/features.sh"

trap 'stop_sudo_keepalive' EXIT

main() {
    if ! require_macos; then
        exit 1
    fi

    run_step "Check admin group" ensure_admin_user
    run_step "Acquire sudo session" ensure_sudo_session
    run_step "Install or fix git in PATH" ensure_git_installed
    run_step "Install Homebrew" install_homebrew
    run_step "Ensure runtime dependencies" ensure_runtime_dependencies
    run_step "Report app versions" report_installed_app_versions
    run_step_interactive "Configure firmware password" configure_firmware_password
    run_step "Remove Deep Freeze / Faronics" remove_deepfreeze_and_faronics
    run_step "Create sysmon command" create_sysmon_command
    run_step "Configure bash alias" ensure_bash_alias
    run_step "Configure power management" configure_power_management
    run_step "Apply performance tweaks" configure_performance_tweaks
    run_step_interactive "Install required software" install_required_software

    print_summary
}

main "$@"
