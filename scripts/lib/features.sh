#!/bin/bash

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

    if ! sudo mdutil -a -i off >/dev/null 2>&1; then
        print_warn "Failed to disable Spotlight indexing."
        had_error=1
    fi

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

    defaults write com.apple.dashboard mcx-disabled -boolean YES >/dev/null 2>&1 || true

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

get_cpu_temp() {
    if command -v osx-cpu-temp >/dev/null 2>&1; then
        osx-cpu-temp 2>/dev/null || echo "unavailable"
        return
    fi

    if command -v istats >/dev/null 2>&1; then
        istats cpu temp --no-graphs 2>/dev/null | head -n 1 | sed 's/^ *//' || echo "unavailable"
        return
    fi

    if command -v powermetrics >/dev/null 2>&1; then
        sudo -n powermetrics --samplers smc -n 1 2>/dev/null | grep -i 'CPU die temperature' | head -n 1 | sed 's/^ *//' || echo "unavailable (sudo permission required)"
        return
    fi

    echo "unavailable"
}

print_once() {
    echo "System Monitor - $(date)"
    echo "=============================================="
    echo "Host: $(scutil --get ComputerName 2>/dev/null || hostname)"
    echo "Uptime: $(uptime | sed 's/^ *//')"
    echo "CPU Temp: $(get_cpu_temp)"
    echo ""
    echo "CPU Summary"
    top -l 1 | grep -E '^CPU usage:' || true
    echo ""
    echo "Memory Summary"
    vm_stat | head -n 6 || true
    echo ""
    echo "Disk"
    df -h / || true
    echo ""
    echo "Top Processes (CPU)"
    ps -Ao pid,ppid,%cpu,%mem,comm -r | head -n 12
}

if [[ "${1:-}" == "--once" ]]; then
    print_once
    exit 0
fi

while true; do
    clear
    print_once
    echo ""
    echo "Refreshing every 2 seconds. Press Ctrl+C to exit."
    sleep 2
done
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
    print_info "Sysmon hotkey setup is disabled by configuration."
    return 0
}

get_brew_cask_version() {
    local token="$1"
    local json

    json="$(brew_cmd info --cask --json=v2 "$token" 2>/dev/null || true)"
    if [[ -z "$json" ]]; then
        echo "unknown"
        return 0
    fi

    if command -v python3 >/dev/null 2>&1; then
        python3 - <<PY
import json
import sys

raw = '''$json'''
try:
    data = json.loads(raw)
    casks = data.get("casks", [])
    if not casks:
        print("unknown")
    else:
        print(casks[0].get("version", "unknown"))
except Exception:
    print("unknown")
PY
    else
        echo "unknown"
    fi
}

record_cask_lock() {
    local token="$1"
    local app_path="$2"
    local lock_dir="$HOME/.acidanthera/cask-locks"
    local lock_file="$lock_dir/$token.lock"
    local macos_ver
    local installed_ver
    local brew_ver

    macos_ver="$(sw_vers -productVersion 2>/dev/null || echo unknown)"
    installed_ver="$(get_app_version "$app_path")"
    brew_ver="$(get_brew_cask_version "$token")"

    mkdir -p "$lock_dir" || return 1
    cat > "$lock_file" <<EOF
token=$token
macos=$macos_ver
installed_app_version=$installed_ver
brew_cask_version=$brew_ver
locked_at=$(date '+%Y-%m-%d %H:%M:%S')
EOF

    print_info "Locked $token to current supported release metadata: $lock_file"
    return 0
}

reinstall_cask_app() {
    local token="$1"
    local app_path="$2"
    local display_name="$3"
    local supported_ver
    local attempt=1
    local max_attempts=2

    if ! brew_is_healthy; then
        print_warn "Homebrew unavailable; cannot install $display_name."
        return 1
    fi

    supported_ver="$(get_brew_cask_version "$token")"
    if [[ "$supported_ver" == "unknown" ]]; then
        print_warn "$display_name cask metadata is unavailable for this Homebrew/macOS state."
    fi
    print_info "$display_name supported cask version for this macOS: $supported_ver"

    print_info "Removing old $display_name version (if present)..."
    brew_cmd uninstall --cask --force "$token" >/dev/null 2>&1 || true
    if [[ -d "$app_path" ]]; then
        if ! sudo rm -rf "$app_path"; then
            print_warn "Could not remove old app bundle: $app_path"
        fi
    fi

    while [[ "$attempt" -le "$max_attempts" ]]; do
        print_info "Installing latest supported $display_name... (attempt $attempt/$max_attempts)"
        if HOMEBREW_NO_AUTO_UPDATE=1 brew_cmd install --cask "$token"; then
            break
        fi

        if [[ "$attempt" -lt "$max_attempts" ]]; then
            print_warn "Install attempt failed for $display_name. Repairing Homebrew and retrying once."
            repair_homebrew_environment || true
            brew_cmd update --force --quiet >/dev/null 2>&1 || true
        fi

        attempt=$((attempt + 1))
    done

    if [[ "$attempt" -gt "$max_attempts" ]]; then
        print_warn "Failed to install $display_name via cask $token after retries."
        return 1
    fi

    if [[ -d "$app_path" ]]; then
        print_ok "$display_name installed. Version: $(get_app_version "$app_path")"
    else
        print_warn "$display_name install command completed but app bundle not found at $app_path"
    fi

    record_cask_lock "$token" "$app_path" || true
    return 0
}

verify_required_software_present() {
    local had_error=0
    local blender_app="/Applications/Blender.app"
    local android_app="/Applications/Android Studio.app"
    local azure_app="/Applications/Azure Data Studio.app"
    local packet_tracer_app=""

    if [[ -d "$blender_app" ]]; then
        print_ok "Verified Blender installation."
    else
        print_warn "Blender is not installed at expected path: $blender_app"
        had_error=1
    fi

    if [[ -d "$android_app" ]]; then
        print_ok "Verified Android Studio installation."
    else
        print_warn "Android Studio is not installed at expected path: $android_app"
        had_error=1
    fi

    if [[ -d "$azure_app" ]]; then
        print_ok "Verified Azure Data Studio installation."
    else
        print_warn "Azure Data Studio is not installed at expected path: $azure_app"
        had_error=1
    fi

    packet_tracer_app="$(find /Applications -maxdepth 1 -type d -name '*Packet*Tracer*.app' | head -n 1)"
    if [[ -n "$packet_tracer_app" ]]; then
        print_ok "Verified Cisco Packet Tracer installation: $packet_tracer_app"
    else
        print_warn "Cisco Packet Tracer app bundle was not found in /Applications."
        had_error=1
    fi

    if [[ "$had_error" -eq 1 ]]; then
        return 1
    fi

    return 0
}

install_packet_tracer() {
    local dmg_url=""
    local dmg_file="/tmp/cisco_packet_tracer.dmg"
    local mount_point="/tmp/packet_tracer_mount"
    local pkg_path
    local app_path

    print_info "Installing Cisco Packet Tracer..."

    dmg_url="$(resolve_packet_tracer_dmg_url)"

    if [[ -z "$dmg_url" ]]; then
        print_warn "Could not resolve Cisco Packet Tracer DMG URL."
        print_warn "Expected a .dmg asset under release tag 'cisco' in the configured GitHub repo."
        print_warn "Set PACKET_TRACER_DMG_URL manually to override."
        return 1
    fi

    print_info "Using Packet Tracer DMG URL: $dmg_url"

    if ! curl -fL "$dmg_url" -o "$dmg_file"; then
        print_warn "Failed to download Cisco Packet Tracer DMG."
        return 1
    fi

    sudo rm -rf "$mount_point" >/dev/null 2>&1 || true
    sudo mkdir -p "$mount_point" >/dev/null 2>&1 || true

    if ! hdiutil attach "$dmg_file" -quiet -nobrowse -mountpoint "$mount_point" >/dev/null 2>&1; then
        print_warn "Failed to mount Cisco Packet Tracer DMG."
        rm -f "$dmg_file" >/dev/null 2>&1 || true
        return 1
    fi

    pkg_path="$(find "$mount_point" -maxdepth 3 -name '*.pkg' | head -n 1)"
    app_path="$(find "$mount_point" -maxdepth 3 -name '*.app' | head -n 1)"

    if [[ -n "$pkg_path" ]]; then
        print_info "Installing Packet Tracer package: $pkg_path"
        if ! sudo installer -pkg "$pkg_path" -target / >/dev/null 2>&1; then
            print_warn "Packet Tracer package install failed."
            hdiutil detach "$mount_point" -force >/dev/null 2>&1 || true
            rm -f "$dmg_file" >/dev/null 2>&1 || true
            return 1
        fi
    elif [[ -n "$app_path" ]]; then
        print_info "Copying Packet Tracer app bundle to /Applications"
        sudo rm -rf "/Applications/$(basename "$app_path")" >/dev/null 2>&1 || true
        if ! sudo ditto "$app_path" "/Applications/$(basename "$app_path")" >/dev/null 2>&1; then
            print_warn "Packet Tracer app copy failed."
            hdiutil detach "$mount_point" -force >/dev/null 2>&1 || true
            rm -f "$dmg_file" >/dev/null 2>&1 || true
            return 1
        fi
    else
        print_warn "No .pkg or .app found inside Packet Tracer DMG."
        hdiutil detach "$mount_point" -force >/dev/null 2>&1 || true
        rm -f "$dmg_file" >/dev/null 2>&1 || true
        return 1
    fi

    hdiutil detach "$mount_point" -force >/dev/null 2>&1 || true
    rm -f "$dmg_file" >/dev/null 2>&1 || true
    print_ok "Cisco Packet Tracer installation completed."
    return 0
}

resolve_packet_tracer_dmg_url() {
    local explicit_url="${PACKET_TRACER_DMG_URL:-}"
    local release_repo="${PACKET_TRACER_RELEASE_REPO:-kpawnd/acidanthera}"
    local release_tag="${PACKET_TRACER_RELEASE_TAG:-cisco}"
    local api_url
    local json

    if [[ -n "$explicit_url" ]]; then
        echo "$explicit_url"
        return 0
    fi

    api_url="https://api.github.com/repos/${release_repo}/releases/tags/${release_tag}"
    json="$(curl -fsSL "$api_url" 2>/dev/null || true)"

    if [[ -z "$json" ]]; then
        echo ""
        return 1
    fi

    if command -v python3 >/dev/null 2>&1; then
        python3 - <<PY
import json

raw = '''$json'''
try:
    data = json.loads(raw)
except Exception:
    print("")
    raise SystemExit(0)

assets = data.get("assets", [])
urls = [a.get("browser_download_url", "") for a in assets]
urls = [u for u in urls if u.lower().endswith(".dmg")]

preferred = [u for u in urls if "packet" in u.lower() and "tracer" in u.lower()]
if preferred:
    print(preferred[0])
elif urls:
    print(urls[0])
else:
    print("")
PY
        return 0
    fi

    echo "$json" | grep -Eo '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+\.dmg"' | head -n 1 | sed -E 's/^.*"(https:[^"]+\.dmg)"$/\1/'
    return 0
}

install_required_software() {
    local had_error=0

    print_info "Installing required software set..."

    repair_homebrew_environment || true

    reinstall_cask_app "blender" "/Applications/Blender.app" "Blender" || had_error=1
    reinstall_cask_app "android-studio" "/Applications/Android Studio.app" "Android Studio" || had_error=1
    reinstall_cask_app "azure-data-studio" "/Applications/Azure Data Studio.app" "Azure Data Studio" || had_error=1

    install_packet_tracer || had_error=1
    verify_required_software_present || had_error=1

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
    echo "2. App version report for Azure Data Studio, Blender, and Android Studio."
    echo "3. Firmware password change routine (interactive user input)."
    echo "4. Known-path Deep Freeze / Faronics cleanup attempt."
    echo "5. Power schedule with pmset (Mon-Sat)."
    echo "   - Wake/Power on: 07:00"
    echo "   - Shutdown: 21:30"
    echo "6. AC wake enabled and Power Nap disabled."
    echo "7. System monitor command installed: ~/.local/bin/sysmon"
    echo "8. Bash alias added: sysmon"
    echo "9. Sysmon hotkey setup disabled."
    echo "10. Performance tweaks applied (Spotlight/animations/Dock)."
    echo "11. Reinstall target apps and record cask lock metadata."
    echo "12. Cisco Packet Tracer install from GitHub release tag cisco (or PACKET_TRACER_DMG_URL override)."
    echo ""
    echo "Use now:"
    echo "- sysmon           (live terminal monitor)"
    echo "- sysmon --once    (single snapshot)"
    echo ""
    if [[ "$FIRMWARE_PASSWORD_CHANGED" -eq 1 ]]; then
        print_warn "Firmware password was changed. Restart is recommended before validation."
    fi
    print_info "Open a new shell (or run: source ~/.bashrc) to use the alias immediately."
}
