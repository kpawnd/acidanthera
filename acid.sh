#!/bin/bash

set -uo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

TOTAL_STEPS=0
FAILED_STEPS=0
FIRMWARE_PASSWORD_CHANGED=0

print_ok() {
    echo -e "${GREEN}[OK]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_err() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_info_inline() {
    # Refreshes the same terminal line for long-running progress updates.
    if [[ -t 1 ]]; then
        printf "\r\033[2K${BLUE}[INFO]${NC} %s" "$1"
    else
        print_info "$1"
    fi
}

clear_inline_status() {
    if [[ -t 1 ]]; then
        printf "\r\033[2K"
    fi
}

run_step() {
    local step_name="$1"
    shift

    TOTAL_STEPS=$((TOTAL_STEPS + 1))
    print_info "$step_name"

    if "$@"; then
        print_ok "$step_name completed"
    else
        FAILED_STEPS=$((FAILED_STEPS + 1))
        print_warn "$step_name failed, continuing"
    fi
}

require_macos() {
    if [[ "$(uname -s)" != "Darwin" ]]; then
        print_err "This script is for macOS only."
        return 1
    fi

    return 0
}

ensure_admin_user() {
    if ! id -Gn "$USER" | tr ' ' '\n' | grep -qx "admin"; then
        print_warn "Current user is not in the admin group."
        print_warn "Power settings and service setup may fail without admin privileges."
        return 0
    fi

    print_ok "Admin group membership detected for user: $USER"
    return 0
}

ensure_sudo_session() {
    print_info "Requesting sudo access (needed for system changes)."
    sudo -v
}

ensure_git_installed() {
    local clt_label

    # Normalize PATH so standard macOS binaries are resolvable.
    export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:$PATH"

    if command -v git >/dev/null 2>&1; then
        print_ok "git is already available: $(command -v git)"
        return 0
    fi

    # If git exists but PATH was missing it, recover immediately.
    if [[ -x /usr/bin/git ]]; then
        print_warn "git exists at /usr/bin/git but was missing from PATH. PATH corrected."
        return 0
    fi

    print_warn "git is not installed. Attempting to install Command Line Tools."

    # Try non-interactive CLT install first.
    clt_label="$(softwareupdate -l 2>/dev/null | awk -F'* ' '/Command Line Tools/ {print $2}' | sed 's/^Label: //' | tail -n 1)"
    if [[ -n "$clt_label" ]]; then
        print_info "Installing: $clt_label"
        if sudo softwareupdate -i "$clt_label" --verbose; then
            if command -v git >/dev/null 2>&1 || [[ -x /usr/bin/git ]]; then
                print_ok "git installed successfully via Command Line Tools."
                return 0
            fi
        fi
    fi

    # Fall back to Apple's interactive installer trigger.
    print_warn "Automatic CLT install did not complete. Triggering interactive installer."
    xcode-select --install >/dev/null 2>&1 || true

    if command -v git >/dev/null 2>&1 || [[ -x /usr/bin/git ]]; then
        print_ok "git is now available."
        return 0
    fi

    print_err "git is still unavailable. Complete Command Line Tools installation, then rerun this script."
    return 1
}

brew_is_healthy() {
    if ! command -v brew >/dev/null 2>&1; then
        return 1
    fi

    if brew --version >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

repair_homebrew_shallow_clones() {
    local brew_repo
    local core_tap
    local cask_tap
    local had_error=0

    if ! command -v brew >/dev/null 2>&1; then
        print_warn "brew is unavailable; cannot repair shallow clones."
        return 1
    fi

    brew_repo="$(brew --repository 2>/dev/null || true)"
    if [[ -z "$brew_repo" ]]; then
        if [[ -d /opt/homebrew ]]; then
            brew_repo="/opt/homebrew"
        elif [[ -d /usr/local/Homebrew ]]; then
            brew_repo="/usr/local/Homebrew"
        fi
    fi

    if [[ -z "$brew_repo" || ! -d "$brew_repo" ]]; then
        print_warn "Could not resolve Homebrew repository path for shallow clone repair."
        return 1
    fi

    core_tap="$brew_repo/Library/Taps/homebrew/homebrew-core"
    cask_tap="$brew_repo/Library/Taps/homebrew/homebrew-cask"

    if [[ -d "$core_tap/.git" ]]; then
        print_info "Repairing shallow clone: homebrew-core"
        if ! git -C "$core_tap" fetch --unshallow >/dev/null 2>&1; then
            print_warn "Could not unshallow homebrew-core."
            had_error=1
        fi
    fi

    if [[ -d "$cask_tap/.git" ]]; then
        print_info "Repairing shallow clone: homebrew-cask"
        if ! git -C "$cask_tap" fetch --unshallow >/dev/null 2>&1; then
            print_warn "Could not unshallow homebrew-cask."
            had_error=1
        fi
    fi

    if [[ "$had_error" -eq 1 ]]; then
        return 1
    fi

    return 0
}

configure_firmware_password() {
    local answer

    if [[ "$(sysctl -n machdep.cpu.brand_string 2>/dev/null || true)" != *"Intel"* ]]; then
        print_warn "Firmware password tool is not supported on this Mac type. Skipping."
        return 0
    fi

    if [[ ! -x /usr/sbin/firmwarepasswd ]]; then
        print_warn "firmwarepasswd tool not found. Skipping firmware password step."
        return 0
    fi

    read -r -p "Change firmware password now? (y/N): " answer
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        print_info "Firmware password change skipped by user."
        return 0
    fi

    print_info "Current firmware password status:"
    sudo /usr/sbin/firmwarepasswd -check || print_warn "Could not read current firmware password status."

    print_info "You will now be prompted for password input by firmwarepasswd."
    print_info "If a firmware password already exists, provide current password first."

    if ! sudo /usr/sbin/firmwarepasswd -setpasswd; then
        print_warn "Firmware password change did not complete."
        return 1
    fi

    FIRMWARE_PASSWORD_CHANGED=1
    print_ok "Firmware password change completed."
    return 0
}

install_homebrew() {
    if ! ensure_git_installed; then
        print_err "Cannot install Homebrew without git in PATH."
        return 1
    fi

    if brew_is_healthy; then
        print_ok "Homebrew is already installed."
        return 0
    fi

    if command -v brew >/dev/null 2>&1; then
        print_warn "Homebrew is installed but appears broken. Attempting reinstall."
    fi

    print_info "Installing Homebrew..."
    if ! NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
        if command -v brew >/dev/null 2>&1; then
            print_warn "Homebrew install/update failed. Attempting shallow clone repair and retry."
            repair_homebrew_shallow_clones || true
            brew update --force --quiet >/dev/null 2>&1 || true
        fi

        if brew_is_healthy; then
            print_ok "Homebrew is healthy after repair/retry."
            return 0
        fi

        print_err "Homebrew installation failed."
        return 1
    fi

    if [[ -x /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x /usr/local/bin/brew ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi

    if ! brew_is_healthy; then
        print_err "Homebrew is still unavailable or unhealthy after reinstall attempt."
        return 1
    fi

    print_ok "Homebrew installed successfully."
    return 0
}

remove_deepfreeze_and_faronics() {
    local had_error=0
    local tmp_list
    tmp_list="$(mktemp)"
    local search_roots
    search_roots=(
        "/Applications"
        "/Library"
        "/private/var/db/receipts"
        "/private/var/root/Library"
        "$HOME/Library"
    )

    print_info "Searching for Deep Freeze / Faronics launch services..."

    launchctl list 2>/dev/null | awk '{print $3}' | grep -Ei 'faronics|deep[[:space:]_-]*freeze|deepfreeze' > "$tmp_list" || true

    while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        print_info "Stopping launch service: $svc"

        if ! sudo launchctl bootout system "$svc" >/dev/null 2>&1; then
            sudo launchctl remove "$svc" >/dev/null 2>&1 || {
                print_warn "Could not fully remove service: $svc"
                had_error=1
            }
        fi
    done < "$tmp_list"

    : > "$tmp_list"

    print_info "Searching plist files for Deep Freeze / Faronics services..."
    find /Library/LaunchDaemons /Library/LaunchAgents "$HOME/Library/LaunchAgents" \
        -type f \( -iname '*faronics*.plist' -o -iname '*deep*freeze*.plist' -o -iname '*deepfreeze*.plist' \) \
        2>/dev/null > "$tmp_list" || true

    while IFS= read -r plist; do
        [[ -z "$plist" ]] && continue
        print_info "Removing plist: $plist"
        sudo launchctl unload "$plist" >/dev/null 2>&1 || true
        if ! sudo rm -f "$plist"; then
            print_warn "Could not delete plist: $plist"
            had_error=1
        fi
    done < "$tmp_list"

    : > "$tmp_list"

    print_info "Recursively removing Deep Freeze / Faronics files and folders..."

    local matches_found=0
    local entry
    local use_python_scanner=0

    if command -v python3 >/dev/null 2>&1; then
        use_python_scanner=1
        print_info "Using Python scanner for faster traversal and cleaner progress updates."
    else
        print_warn "python3 not found; using bash scanner fallback."
    fi

    for root in "${search_roots[@]}"; do
        if [[ ! -d "$root" ]]; then
            continue
        fi

        print_info "Scanning root: $root"

        if [[ "$use_python_scanner" -eq 1 ]]; then
            while IFS= read -r path; do
                [[ -z "$path" ]] && continue
                matches_found=$((matches_found + 1))
                clear_inline_status
                print_info "Deleting: $path"
                if ! sudo rm -rf "$path"; then
                    print_warn "Could not delete: $path"
                    had_error=1
                fi
            done < <(
                python3 - "$root" <<'PY'
import os
import re
import sys

root = sys.argv[1]
pattern = re.compile(r"faronics|deep[\s_-]*freeze|deepfreeze", re.IGNORECASE)

for dirpath, dirnames, filenames in os.walk(root, topdown=True, followlinks=False):
    sys.stderr.write(f"\r\033[2K\033[0;34m[INFO]\033[0m Scanning path: {dirpath}")
    sys.stderr.flush()

    base = os.path.basename(dirpath)
    if pattern.search(base):
        print(dirpath)

    for fname in filenames:
        if pattern.search(fname):
            print(os.path.join(dirpath, fname))

sys.stderr.write("\r\033[2K")
sys.stderr.flush()
PY
            )
        else
            for entry in "$root"/* "$root"/.*; do
                [[ ! -e "$entry" ]] && continue
                [[ "$entry" == "$root/." || "$entry" == "$root/.." ]] && continue

                print_info_inline "Scanning path: $entry"

                while IFS= read -r path; do
                    [[ -z "$path" ]] && continue
                    matches_found=$((matches_found + 1))
                    clear_inline_status
                    print_info "Deleting: $path"
                    if ! sudo rm -rf "$path"; then
                        print_warn "Could not delete: $path"
                        had_error=1
                    fi
                done < <(
                    find "$entry" -xdev \( -iname '*faronics*' -o -iname '*deep*freeze*' -o -iname '*deepfreeze*' \) 2>/dev/null
                )
            done

            while IFS= read -r path; do
                [[ -z "$path" ]] && continue
                matches_found=$((matches_found + 1))
                clear_inline_status
                print_info "Deleting: $path"
                if ! sudo rm -rf "$path"; then
                    print_warn "Could not delete: $path"
                    had_error=1
                fi
            done < <(
                find "$root" -maxdepth 1 -xdev \( -iname '*faronics*' -o -iname '*deep*freeze*' -o -iname '*deepfreeze*' \) 2>/dev/null
            )
        fi

        clear_inline_status
        print_info "Completed root scan: $root"
    done

    print_info "Recursive scan complete. Matches found: $matches_found"

    rm -f "$tmp_list" || true

    if [[ "$had_error" -eq 1 ]]; then
        print_warn "Deep Freeze / Faronics cleanup completed with some failures."
        return 1
    fi

    print_ok "Deep Freeze / Faronics cleanup completed."
    return 0
}

configure_power_management() {
    local had_error=0

    print_info "Applying power management settings..."

    if ! sudo pmset repeat cancel; then
        print_warn "Failed to clear existing pmset repeat schedule."
        had_error=1
    fi

    if ! sudo pmset repeat wakeorpoweron MTWRFS 07:00:00; then
        print_warn "Failed to set wake/power on schedule."
        had_error=1
    fi

    if ! sudo pmset repeat shutdown MTWRFS 21:30:00; then
        print_warn "Failed to set shutdown schedule."
        had_error=1
    fi

    if ! sudo pmset -a acwake 1; then
        print_warn "Failed to enable AC wake."
        had_error=1
    fi

    if ! sudo pmset -a powernap 0; then
        print_warn "Failed to disable Power Nap."
        had_error=1
    fi

    if [[ "$had_error" -eq 1 ]]; then
        return 1
    fi

    print_ok "Power schedule set for Mon-Sat: on at 07:00, off at 21:30."
    print_ok "AC wake enabled and Power Nap disabled."
    return 0
}

configure_performance_tweaks() {
    local had_error=0

    print_info "Applying performance tweaks..."

    # Spotlight Control: disable indexing.
    if ! sudo mdutil -a -i off >/dev/null 2>&1; then
        print_warn "Failed to disable Spotlight indexing."
        had_error=1
    fi

    # Animation Removal: disable common UI animations.
    if ! defaults write NSGlobalDomain NSAutomaticWindowAnimationsEnabled -bool false; then
        print_warn "Failed to disable automatic window animations."
        had_error=1
    fi
    if ! defaults write NSGlobalDomain NSWindowResizeTime -float 0.001; then
        print_warn "Failed to reduce window resize animation time."
        had_error=1
    fi
    if ! defaults write com.apple.dock launchanim -bool false; then
        print_warn "Failed to disable Dock launch animation."
        had_error=1
    fi

    # Dashboard Management: disable legacy dashboard where supported.
    defaults write com.apple.dashboard mcx-disabled -boolean YES >/dev/null 2>&1 || true

    # Dock Optimization: reduce mission control/springboard timings.
    if ! defaults write com.apple.dock expose-animation-duration -float 0; then
        print_warn "Failed to set expose animation duration."
        had_error=1
    fi
    defaults write com.apple.dock springboard-show-duration -int 0 >/dev/null 2>&1 || true
    defaults write com.apple.dock springboard-hide-duration -int 0 >/dev/null 2>&1 || true

    if ! killall Dock >/dev/null 2>&1; then
        print_warn "Could not restart Dock automatically."
        had_error=1
    fi

    if [[ "$had_error" -eq 1 ]]; then
        return 1
    fi

    print_ok "Performance tweaks applied."
    return 0
}

create_sysmon_command() {
    local target_dir="$HOME/.local/bin"
    local target_file="$target_dir/sysmon"

    mkdir -p "$target_dir" || return 1

    cat > "$target_file" <<'EOF'
#!/bin/bash
set -uo pipefail

mode="terminal"
if [[ "${1:-}" == "--window" ]]; then
    mode="window"
fi

report_file="/tmp/sysmon_report_$(date +%Y%m%d_%H%M%S).txt"

{
    echo "System Monitor Report - $(date)"
    echo "========================================"
    echo ""

    echo "Host: $(scutil --get ComputerName 2>/dev/null || hostname)"
    echo "Uptime: $(uptime | sed 's/^ *//')"
    echo ""

    echo "CPU"
    echo "----------------------------------------"
    sysctl -n machdep.cpu.brand_string 2>/dev/null || true
    top -l 1 | grep -E '^CPU usage:' || true
    if command -v osx-cpu-temp >/dev/null 2>&1; then
        echo "CPU Temp: $(osx-cpu-temp 2>/dev/null || echo unavailable)"
    elif command -v istats >/dev/null 2>&1; then
        echo "CPU Temp:"
        istats cpu temp --no-graphs 2>/dev/null || echo "unavailable"
    elif command -v powermetrics >/dev/null 2>&1; then
        echo "CPU Temp (powermetrics):"
        sudo -n powermetrics --samplers smc -n 1 2>/dev/null | grep -i 'CPU die temperature' || echo "unavailable (requires sudo permission)"
    else
        echo "CPU Temp: unavailable (install osx-cpu-temp or iStats)"
    fi
    echo ""

    echo "Memory"
    echo "----------------------------------------"
    vm_stat | head -n 8 || true
    echo ""

    echo "Disk"
    echo "----------------------------------------"
    df -h / || true
    echo ""

    echo "Battery"
    echo "----------------------------------------"
    pmset -g batt || true
    echo ""

    echo "Network"
    echo "----------------------------------------"
    networksetup -listallhardwareports 2>/dev/null | grep -E 'Hardware Port|Device:' || true
} > "$report_file"

if [[ "$mode" == "window" ]]; then
    open -a TextEdit "$report_file"
else
    cat "$report_file"
fi
EOF

    chmod +x "$target_file" || return 1
    print_ok "System monitor command created: $target_file"
    return 0
}

ensure_bash_alias() {
    local bashrc="$HOME/.bashrc"
    local bash_profile="$HOME/.bash_profile"
    local alias_line='alias sysmon="$HOME/.local/bin/sysmon"'

    touch "$bashrc" "$bash_profile" || return 1

    if ! grep -Fxq "$alias_line" "$bashrc"; then
        echo "$alias_line" >> "$bashrc" || return 1
        print_ok "Added sysmon alias to $bashrc"
    else
        print_ok "sysmon alias already exists in $bashrc"
    fi

    if ! grep -Fxq "$alias_line" "$bash_profile"; then
        echo "$alias_line" >> "$bash_profile" || return 1
        print_ok "Added sysmon alias to $bash_profile"
    else
        print_ok "sysmon alias already exists in $bash_profile"
    fi

    return 0
}

install_and_configure_skhd() {
    local had_error=0
    local skhd_formula="koekeishiya/formulae/skhd"

    print_info "Installing and configuring skhd for hotkey trigger..."

    if ! ensure_git_installed; then
        print_warn "git is unavailable; skipping skhd setup."
        return 1
    fi

    if ! brew_is_healthy; then
        print_warn "Homebrew is unavailable or unhealthy; skipping skhd setup."
        return 1
    fi

    if ! brew list --formula skhd >/dev/null 2>&1; then
        print_info "Adding tap for skhd formula..."
        if ! brew tap koekeishiya/formulae >/dev/null 2>&1; then
            print_warn "Failed to add koekeishiya/formulae tap."
        fi

        print_info "Installing skhd from tap..."
        if ! brew install "$skhd_formula"; then
            print_warn "Primary skhd install failed. Trying HEAD build."
            if ! brew install --HEAD "$skhd_formula"; then
                print_warn "Failed to install skhd from koekeishiya/formulae."
                print_warn "Homebrew cannot find the formula in current repositories."
                return 1
            fi
        fi
    fi

    local skhd_bin
    skhd_bin="$(brew --prefix)/bin/skhd"

    if ! cat > "$HOME/.skhdrc" <<'EOF'
# Launch system monitor in Terminal with Option+Command+Shift+S
alt + cmd + shift - s : /usr/bin/osascript -e 'tell application "Terminal" to activate' -e 'tell application "Terminal" to do script "sysmon"'
EOF
    then
        print_warn "Could not write ~/.skhdrc"
        had_error=1
    fi

    local plist_dir="$HOME/Library/LaunchAgents"
    local plist_file="$plist_dir/com.acidanthera.sysmon.skhd.plist"

    mkdir -p "$plist_dir" || {
        print_warn "Could not create LaunchAgents directory."
        return 1
    }

    if ! cat > "$plist_file" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.acidanthera.sysmon.skhd</string>
    <key>ProgramArguments</key>
    <array>
        <string>$skhd_bin</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$HOME/Library/Logs/skhd.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/skhd.error.log</string>
</dict>
</plist>
EOF
    then
        print_warn "Could not write skhd LaunchAgent plist."
        return 1
    fi

    launchctl unload "$plist_file" >/dev/null 2>&1 || true
    if ! launchctl load "$plist_file"; then
        print_warn "Could not load skhd LaunchAgent."
        had_error=1
    fi

    print_ok "skhd hotkey service configured."
    print_warn "Grant Accessibility permission to skhd in System Settings > Privacy & Security > Accessibility."
    print_ok "Hotkey set: Option + Command + Shift + S"

    if [[ "$had_error" -eq 1 ]]; then
        return 1
    fi

    return 0
}

print_summary() {
    echo ""
    echo "Execution summary:"
    echo "- Total steps: $TOTAL_STEPS"
    echo "- Failed steps: $FAILED_STEPS"

    if [[ "$FAILED_STEPS" -eq 0 ]]; then
        print_ok "All steps completed successfully."
    else
        print_warn "Script completed with some failures. Review warnings above."
    fi

    echo ""
    echo "What is configured:"
    echo "1. Homebrew installation attempt."
    echo "2. Firmware password change routine (interactive user input)."
    echo "3. Recursive Deep Freeze / Faronics cleanup attempt."
    echo "4. Power schedule with pmset (Mon-Sat)."
    echo "   - Wake/Power on: 07:00"
    echo "   - Shutdown: 21:30"
    echo "5. AC wake enabled and Power Nap disabled."
    echo "6. System monitor command installed: ~/.local/bin/sysmon"
    echo "7. Bash alias added: sysmon"
    echo "8. skhd service setup for Option + Command + Shift + S"
    echo "9. Performance tweaks applied (Spotlight/animations/Dock)."
    echo ""
    echo "Use now:"
    echo "- sysmon           (terminal output)"
    echo "- sysmon --window  (opens report in TextEdit)"
    echo ""
    if [[ "$FIRMWARE_PASSWORD_CHANGED" -eq 1 ]]; then
        print_warn "Firmware password was changed. Restart is recommended before validation."
    fi
    print_info "Open a new shell (or run: source ~/.bashrc) to use the alias immediately."
}

main() {
    if ! require_macos; then
        exit 1
    fi

    run_step "Check admin group" ensure_admin_user
    run_step "Acquire sudo session" ensure_sudo_session
    run_step "Install or fix git in PATH" ensure_git_installed
    run_step "Install Homebrew" install_homebrew
    run_step "Configure firmware password" configure_firmware_password
    run_step "Remove Deep Freeze / Faronics" remove_deepfreeze_and_faronics
    run_step "Create sysmon command" create_sysmon_command
    run_step "Configure bash alias" ensure_bash_alias
    run_step "Configure power management" configure_power_management
    run_step "Install and configure skhd" install_and_configure_skhd
    run_step "Apply performance tweaks" configure_performance_tweaks

    print_summary
}

main "$@"
