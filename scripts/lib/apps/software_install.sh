#!/bin/bash

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/app_utils.sh"

resolve_release_repo() {
    local override_repo="${RELEASES_REPO:-}"
    local root_dir="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
    local remote_url=""
    local parsed_repo=""

    if [[ -n "$override_repo" ]]; then
        echo "$override_repo"
        return 0
    fi

    remote_url="$(git -C "$root_dir" config --get remote.origin.url 2>/dev/null || true)"
    if [[ -n "$remote_url" ]]; then
        parsed_repo="$(echo "$remote_url" | sed -E 's#^.*github.com[:/]([^/]+/[^/.]+)(\.git)?$#\1#')"
        if [[ -n "$parsed_repo" && "$parsed_repo" != "$remote_url" ]]; then
            echo "$parsed_repo"
            return 0
        fi
    fi

    echo ""
    return 1
}

resolve_homebrew_package_file() {
    local package_name="$1"
    local package_type="$2"
    local brew_repo=""
    local search_root=""

    brew_repo="$(brew_cmd --repository 2>/dev/null || true)"
    if [[ -z "$brew_repo" ]]; then
        if [[ -d /opt/homebrew ]]; then
            brew_repo="/opt/homebrew"
        elif [[ -d /usr/local/Homebrew ]]; then
            brew_repo="/usr/local/Homebrew"
        fi
    fi

    if [[ -z "$brew_repo" ]]; then
        return 1
    fi

    if [[ "$package_type" == "cask" ]]; then
        search_root="$brew_repo/Library/Taps/homebrew/homebrew-cask/Casks"
    else
        search_root="$brew_repo/Library/Taps/homebrew/homebrew-core/Formula"
    fi

    [[ -d "$search_root" ]] || return 1
    find "$search_root" -type f -name "${package_name}.rb" | head -n 1
}

install_disabled_homebrew_package_local_override() {
    local package_name="$1"
    local package_type="$2"
    local stage_file="${3:-}"
    local source_file=""
    local override_root="/tmp/atherion-homebrew-overrides"
    local override_file=""

    source_file="$(resolve_homebrew_package_file "$package_name" "$package_type")"
    if [[ -z "$source_file" ]]; then
        # Upstream cask may be removed/disabled. Create a local override for known packages.
        if [[ "$package_type" == "cask" && "$package_name" == "azure-data-studio" ]]; then
            mkdir -p "$override_root" || return 1
            override_file="$override_root/${package_name}.rb"
            cat > "$override_file" <<'EOF'
cask "azure-data-studio" do
  version :latest
  sha256 :no_check

  url "https://azuredatastudio-update.azurewebsites.net/latest/darwin/stable"
  name "Azure Data Studio"
  desc "Data management tool"
  homepage "https://learn.microsoft.com/sql/azure-data-studio/"

  app "Azure Data Studio.app"
end
EOF
        else
            print_warn "Could not locate local Homebrew definition for $package_name."
            return 1
        fi
    else
        mkdir -p "$override_root" || return 1
        override_file="$override_root/${package_name}.rb"
        cp "$source_file" "$override_file" || return 1

        # Remove disable! guard so Homebrew can evaluate local override.
        sed -E -i '' '/^[[:space:]]*disable![[:space:]].*$/d' "$override_file"
    fi

    echo "Installing local override" > "$stage_file" 2>/dev/null || true
    if [[ "$package_type" == "cask" ]]; then
        HOMEBREW_NO_INSTALL_FROM_API=1 HOMEBREW_NO_AUTO_UPDATE=1 brew_cmd install --cask "$override_file" >/dev/null 2>&1
    else
        HOMEBREW_NO_INSTALL_FROM_API=1 HOMEBREW_NO_AUTO_UPDATE=1 brew_cmd install "$override_file" >/dev/null 2>&1
    fi
}

install_cask_homebrew_only() {
    local token="$1"
    local app_path="$2"
    local display_name="$3"
    local stage_file="${4:-}"

    print_info "Installing $display_name via Homebrew cask..."
    if reinstall_cask_app "$token" "$app_path" "$display_name" "$stage_file"; then
        return 0
    fi

    print_warn "$display_name cask install failed. Trying local override for disabled package."
    if ! install_disabled_homebrew_package_local_override "$token" "cask" "$stage_file"; then
        return 1
    fi

    if [[ -n "$(resolve_installed_app_path "$app_path")" ]]; then
        print_ok "$display_name installed via local Homebrew override."
        return 0
    fi

    print_warn "$display_name install completed but app bundle not found at $app_path"
    return 1
}

install_azure_data_studio_direct_download() {
    local stage_file="${1:-}"
    local download_url="https://download.microsoft.com/download/6b2bfeac-9c1b-4182-9a2f-ce86ff8cc371/azuredatastudio-macos-1.52.0.zip"
    local app_path="/Applications/Azure Data Studio.app"
    local zip_file="/tmp/azuredatastudio.zip"
    local extract_dir="/tmp/azuredatastudio_extract"
    local remote_size=""
    local monitor_pid=""

    if [[ -n "$stage_file" ]]; then
        echo "Checking app" > "$stage_file"
    fi

    print_info "Installing Azure Data Studio..."

    # Fast path: Check if app is already installed
    if [[ -n "$(resolve_installed_app_path "$app_path")" ]]; then
        print_ok "Azure Data Studio already installed. Skipping reinstall."
        return 0
    fi

    # Clean up any prior partial downloads
    rm -f "$zip_file" >/dev/null 2>&1 || true
    rm -rf "$extract_dir" >/dev/null 2>&1 || true
    mkdir -p "$extract_dir" || return 1

    if [[ -n "$stage_file" ]]; then
        echo "Resolving download URL" > "$stage_file"
    fi
    print_info "Resolving Azure Data Studio download URL..."

    remote_size="$(get_remote_file_size "$download_url")" || {
        print_warn "Failed to resolve Azure Data Studio download size."
        return 1
    }

    if [[ -n "$stage_file" ]]; then
        echo "Downloading Azure Data Studio" > "$stage_file"
    fi
    print_info "Downloading Azure Data Studio (approximately $(( remote_size / 1048576 ))MB)..."

    # Background monitor for progress display
    monitor_download_progress "$zip_file" "$stage_file" "Azure Data Studio" "$remote_size" &
    monitor_pid=$!

    # Download with resilience
    if ! download_file_resilient "$download_url" "$zip_file"; then
        kill $monitor_pid 2>/dev/null || true
        wait $monitor_pid 2>/dev/null || true
        print_warn "Failed to download Azure Data Studio."
        return 1
    fi

    kill $monitor_pid 2>/dev/null || true
    wait $monitor_pid 2>/dev/null || true

    if [[ -n "$stage_file" ]]; then
        echo "Extracting Azure Data Studio" > "$stage_file"
    fi
    print_info "Extracting Azure Data Studio..."

    if ! unzip -q "$zip_file" -d "$extract_dir" 2>/dev/null; then
        print_warn "Failed to extract Azure Data Studio ZIP."
        rm -f "$zip_file" >/dev/null 2>&1 || true
        rm -rf "$extract_dir" >/dev/null 2>&1 || true
        return 1
    fi

    if [[ -n "$stage_file" ]]; then
        echo "Moving app to /Applications" > "$stage_file"
    fi
    print_info "Moving Azure Data Studio to /Applications..."

    # Find and move the app bundle
    local extracted_app
    extracted_app="$(find "$extract_dir" -maxdepth 2 -type d -name 'Azure Data Studio.app' | head -n 1)"
    if [[ -z "$extracted_app" ]]; then
        print_warn "Azure Data Studio app not found in extracted ZIP."
        rm -f "$zip_file" >/dev/null 2>&1 || true
        rm -rf "$extract_dir" >/dev/null 2>&1 || true
        return 1
    fi

    # Remove any old version first
    if [[ -d "$app_path" ]]; then
        if ! sudo -n rm -rf "$app_path" 2>/dev/null; then
            sudo rm -rf "$app_path" 2>/dev/null || true
        fi
    fi

    # Move to /Applications
    if ! sudo -n mv "$extracted_app" "$app_path" 2>/dev/null; then
        if ! sudo mv "$extracted_app" "$app_path" 2>/dev/null; then
            print_warn "Failed to move Azure Data Studio to /Applications."
            rm -f "$zip_file" >/dev/null 2>&1 || true
            rm -rf "$extract_dir" >/dev/null 2>&1 || true
            return 1
        fi
    fi

    if [[ -n "$stage_file" ]]; then
        echo "Verifying installation" > "$stage_file"
    fi

    # Cleanup
    rm -f "$zip_file" >/dev/null 2>&1 || true
    rm -rf "$extract_dir" >/dev/null 2>&1 || true

    # Verify installation
    if [[ -n "$(resolve_installed_app_path "$app_path")" ]]; then
        print_ok "Azure Data Studio installed successfully."
        return 0
    else
        print_warn "Azure Data Studio install completed but app not found at $app_path"
        return 1
    fi
}

# ============================================================================
# Cisco Packet Tracer Installation
# ============================================================================

get_packet_tracer_supported_version() {
    local dmg_url=""
    local version="unknown"

    dmg_url="$(resolve_packet_tracer_dmg_url)"
    version="$(extract_version_from_url "$dmg_url")"
    version="$(normalize_packet_tracer_version "$version")"
    echo "$version"
    return 0
}

resolve_packet_tracer_dmg_url() {
    local explicit_url="${PACKET_TRACER_DMG_URL:-}"
    local release_repo="${PACKET_TRACER_RELEASE_REPO:-}"
    local release_tag="${PACKET_TRACER_RELEASE_TAG:-Cisco}"
    local api_url
    local json
    local dmg_url

    if [[ -n "$explicit_url" ]]; then
        echo "$explicit_url"
        return 0
    fi

    if [[ -z "$release_repo" ]]; then
        release_repo="$(resolve_release_repo)"
    fi

    if [[ -z "$release_repo" ]]; then
        return 1
    fi

    api_url="https://api.github.com/repos/${release_repo}/releases/tags/${release_tag}"
    json="$(curl -fsSL "$api_url" 2>&1)" || return 1

    if [[ -z "$json" ]]; then
        return 1
    fi

    if echo "$json" | grep -q '"message"'; then
        return 1
    fi

    local py_lib="${PY_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/py}"
    
    if command -v python3 >/dev/null 2>&1; then
        dmg_url="$(echo "$json" | python3 "$py_lib/github_utils.py" packet-tracer-asset 2>&1)"
        if [[ -n "$dmg_url" && "$dmg_url" != "Unknown error" ]]; then
            echo "$dmg_url"
            return 0
        fi
    fi

    return 1
}

install_packet_tracer() {
    local dmg_url=""
    local dmg_file="/tmp/cisco_packet_tracer.dmg"
    local mount_point="/tmp/packet_tracer_mount"
    local install_log="/tmp/packet_tracer_install.log"
    local app_path
    local installer_bundle="0"
    local installed_app
    local supported_ver="unknown"
    local stage_file="${1:-}"
    # Initialize stage file
    if [[ -n "$stage_file" ]]; then
        echo "Checking app" > "$stage_file"
    fi

    print_info "Installing Cisco Packet Tracer..."

    supported_ver="$(get_packet_tracer_supported_version)"
    installed_app="$(find_installed_packet_tracer_app)"
    if [[ -n "$installed_app" ]]; then
        if should_skip_direct_install "$installed_app" "Cisco Packet Tracer" "$supported_ver"; then
            return 0
        fi
    else
        print_info "Cisco Packet Tracer not currently installed. Proceeding with installation."
    fi

    echo "Resolving download URL" > "$stage_file" 2>/dev/null || true
    dmg_url="$(resolve_packet_tracer_dmg_url)"

    if [[ -z "$dmg_url" ]]; then
        echo "Failed: Could not resolve Packet Tracer URL" > "$stage_file" 2>/dev/null || true
        print_warn "Could not resolve Cisco Packet Tracer DMG URL from GitHub release."
        print_warn "Repository: ${PACKET_TRACER_RELEASE_REPO:-<auto-detected>}, Tag: ${PACKET_TRACER_RELEASE_TAG:-Cisco}"
        print_warn "Verify GitHub release exists, check network/firewall, or set PACKET_TRACER_DMG_URL manually."
        return 1
    fi

    print_info "Using Packet Tracer DMG URL: $dmg_url"

    rm -f "$dmg_file" >/dev/null 2>&1 || true
    echo "Downloading Cisco Packet Tracer" > "$stage_file" 2>/dev/null || true
    monitor_download_progress "$dmg_file" "$stage_file" "Cisco Packet Tracer" "$(get_remote_file_size "$dmg_url")" &
    local monitor_pid=$!
    if ! download_file_resilient "$dmg_url" "$dmg_file"; then
        kill $monitor_pid 2>/dev/null || true
        wait $monitor_pid 2>/dev/null || true
        print_warn "Failed to download Cisco Packet Tracer DMG."
        return 1
    fi
    kill $monitor_pid 2>/dev/null || true
    wait $monitor_pid 2>/dev/null || true

    echo "Verifying download" > "$stage_file" 2>/dev/null || true
    if ! hdiutil verify "$dmg_file" >/dev/null 2>&1; then
        print_warn "Downloaded Cisco Packet Tracer DMG failed integrity verification."
        rm -f "$dmg_file" >/dev/null 2>&1 || true
        return 1
    fi

    rm -rf "$mount_point" >/dev/null 2>&1 || true
    mkdir -p "$mount_point" || return 1

    echo "Mounting DMG" > "$stage_file" 2>/dev/null || true
    if ! hdiutil attach "$dmg_file" -quiet -nobrowse -readonly -mountpoint "$mount_point" >/dev/null 2>&1; then
        local attach_output=""
        local detected_mount=""
        attach_output="$(hdiutil attach "$dmg_file" -nobrowse -readonly 2>/dev/null || true)"
        detected_mount="$(printf '%s\n' "$attach_output" | awk -F'\t' '/\/Volumes\// {print $3}' | tail -n 1)"
        if [[ -n "$detected_mount" && -d "$detected_mount" ]]; then
            mount_point="$detected_mount"
        else
            print_warn "Failed to mount Cisco Packet Tracer DMG."
            rm -f "$dmg_file" >/dev/null 2>&1 || true
            return 1
        fi
    fi

    echo "Locating app bundle" > "$stage_file" 2>/dev/null || true
    app_path="$(find "$mount_point" -maxdepth 5 -name '*Packet*Tracer*.app' | head -n 1)"
    if [[ -z "$app_path" ]]; then
        app_path="$(find "$mount_point" -maxdepth 5 -name '*.app' | head -n 1)"
    fi

    if [[ -n "$app_path" ]]; then
        if is_packet_tracer_installer_bundle "$app_path"; then
            installer_bundle="1"
        fi
    fi

    if [[ -n "$app_path" ]]; then
        if [[ "$installer_bundle" == "1" ]]; then
            : >"$install_log"
            echo "Running installer" > "$stage_file" 2>/dev/null || true
            if ! run_packet_tracer_installer_unattended "$app_path" "$install_log" "$mount_point"; then
                print_warn "Packet Tracer unattended installation failed."
                hdiutil detach "$mount_point" -force >/dev/null 2>&1 || true
                rm -f "$dmg_file" >/dev/null 2>&1 || true
                return 1
            fi
        else
            echo "Copying app bundle to /Applications" > "$stage_file" 2>/dev/null || true
            sudo -n rm -rf "/Applications/$(basename "$app_path")" >/dev/null 2>&1 || sudo rm -rf "/Applications/$(basename "$app_path")" >/dev/null 2>&1 || true
            if ! sudo -n ditto "$app_path" "/Applications/$(basename "$app_path")" >/dev/null 2>&1; then
                if ! sudo ditto "$app_path" "/Applications/$(basename "$app_path")" >/dev/null 2>&1; then
                    print_warn "Packet Tracer app copy failed."
                    hdiutil detach "$mount_point" -force >/dev/null 2>&1 || true
                    rm -f "$dmg_file" >/dev/null 2>&1 || true
                    return 1
                fi
            fi
        fi
    else
        print_warn "No .app found inside Packet Tracer DMG."
        hdiutil detach "$mount_point" -force >/dev/null 2>&1 || true
        rm -f "$dmg_file" >/dev/null 2>&1 || true
        return 1
    fi

    echo "Verifying installation" > "$stage_file" 2>/dev/null || true
    sleep 1
    installed_app="$(find_installed_packet_tracer_app)"
    if [[ -z "$installed_app" ]]; then
        print_warn "Packet Tracer install command completed but app was not found in /Applications."
        find /Applications -maxdepth 3 -type d -name '*[Pp]acket*[Tt]racer*' 2>/dev/null | while read d; do
            print_info "  Found: $d"
        done
        hdiutil detach "$mount_point" -force >/dev/null 2>&1 || true
        rm -f "$dmg_file" >/dev/null 2>&1 || true
        return 1
    fi

    echo "Cleaning up" > "$stage_file" 2>/dev/null || true
    hdiutil detach "$mount_point" -force >/dev/null 2>&1 || true
    rm -f "$dmg_file" >/dev/null 2>&1 || true
    print_ok "Cisco Packet Tracer installation completed: $installed_app"
    return 0
}

install_android_studio_homebrew() {
    local stage_file="${1:-}"
    install_cask_homebrew_only "android-studio" "/Applications/Android Studio.app" "Android Studio" "$stage_file"
}

install_required_software() {
    local had_error=0
    local stage_blender="/tmp/install_stage_blender.txt"
    local stage_android="/tmp/install_stage_android.txt"
    local stage_azure="/tmp/install_stage_azure.txt"
    local stage_packet="/tmp/install_stage_packet.txt"

    print_info "Installing required software set..."
    repair_homebrew_environment || true

    reinstall_cask_app "blender" "/Applications/Blender.app" "Blender" "$stage_blender" &
    spinner_wait_with_stages $! "Installing Blender" "$stage_blender" || had_error=1

    install_android_studio_homebrew "$stage_android" &
    spinner_wait_with_stages $! "Installing Android Studio" "$stage_android" || had_error=1

    install_azure_data_studio_direct_download "$stage_azure" &
    spinner_wait_with_stages $! "Installing Azure Data Studio" "$stage_azure" || had_error=1

    install_packet_tracer "$stage_packet" &
    spinner_wait_with_stages $! "Installing Cisco Packet Tracer" "$stage_packet" || had_error=1

    clear_inline_status
    rm -f "$stage_blender" "$stage_android" "$stage_azure" "$stage_packet" >/dev/null 2>&1 || true
    verify_required_software_present || had_error=1

    if [[ "$had_error" -eq 1 ]]; then
        return 1
    fi

    return 0
}
