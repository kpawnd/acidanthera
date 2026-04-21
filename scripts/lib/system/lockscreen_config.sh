#!/bin/bash

# Best-effort lock screen/login window background customization
# Works across macOS Monterey (12) through Sequoia (15)
# Supports both SIP-enabled and SIP-disabled (OCLP) systems
# Note: macOS does not expose a stable, separate lock-screen image API.

apply_wallpaper_for_user() {
    local target_user="$1"
    local image_path="$2"
    local target_uid

    target_uid="$(id -u "$target_user" 2>/dev/null || true)"
    if [[ -z "$target_uid" ]]; then
        return 1
    fi

    launchctl asuser "$target_uid" sudo -u "$target_user" osascript \
        -e 'tell application "System Events"' \
        -e 'tell every desktop to set picture to POSIX file "'"$image_path"'"' \
        -e 'end tell' >/dev/null 2>&1
}

apply_lockscreen_cache_for_user() {
    local target_user="$1"
    local image_path="$2"
    local generated_uid
    local cache_dir

    generated_uid="$(dscl . -read "/Users/$target_user" GeneratedUID 2>/dev/null | awk '{print $2}')"
    if [[ -z "$generated_uid" ]]; then
        return 1
    fi

    cache_dir="/Library/Caches/Desktop Pictures/$generated_uid"
    if ! sudo mkdir -p "$cache_dir"; then
        return 1
    fi

    # Write both png/jpg variants used by different macOS builds.
    sudo cp "$image_path" "$cache_dir/lockscreen.png" 2>/dev/null || return 1
    sudo cp "$image_path" "$cache_dir/lockscreen.jpg" 2>/dev/null || true
    sudo cp "$image_path" "/Library/Caches/com.apple.desktop.admin.png" 2>/dev/null || true
    sudo chmod 644 "$cache_dir/lockscreen.png" "$cache_dir/lockscreen.jpg" "/Library/Caches/com.apple.desktop.admin.png" >/dev/null 2>&1 || true

    return 0
}

configure_lockscreen_background() {
    local image_url="${LOCKSCREEN_IMAGE_URL:-https://wall.tasw.qzz.io/mac.png}"
    local image_file="/tmp/lockscreen_bg.png"
    local persistent_dir="/Library/Application Support/Atherion"
    local persistent_image="$persistent_dir/lockscreen_bg.png"
    local lock_plist="/Library/Preferences/com.apple.loginwindow"
    
    print_info "Downloading lockscreen image..."
    
    # Download the image
    if ! curl -fsSL --connect-timeout 10 --max-time 60 "$image_url" -o "$image_file"; then
        print_warn "Failed to download lockscreen image from $image_url"
        return 1
    fi
    
    # Verify it's a valid image
    if ! file "$image_file" | grep -q "image"; then
        print_warn "Downloaded file is not a valid image"
        rm -f "$image_file"
        return 1
    fi

    # Persist the image to a system path so settings survive script exit.
    if ! sudo mkdir -p "$persistent_dir"; then
        print_warn "Failed to create lockscreen directory: $persistent_dir"
        rm -f "$image_file"
        return 1
    fi
    if ! sudo cp "$image_file" "$persistent_image"; then
        print_warn "Failed to copy lockscreen image to $persistent_image"
        rm -f "$image_file"
        return 1
    fi
    sudo chmod 644 "$persistent_image" >/dev/null 2>&1 || true
    
    # Check if SIP is disabled (OCLP system)
    local sip_enabled=true
    if csrutil status 2>/dev/null | grep -q "disabled"; then
        sip_enabled=false
        print_info "SIP detected as disabled (OCLP system) - using full lockscreen replacement"
    fi
    
    # For SIP-disabled systems (OCLP), replace actual lockscreen images
    if [[ "$sip_enabled" == "false" ]]; then
        _apply_lockscreen_sip_disabled "$persistent_image"
    fi
    
    # Always set loginwindow-related image paths (works with or without SIP)
    print_info "Applying loginwindow image paths..."
    
    # Copy to system location
    sudo cp "$persistent_image" /Library/Caches/com.apple.loginwindow/lockscreen_bg.png 2>/dev/null || true
    
    # Set via defaults (Monterey-Sequoia compatible)
    if ! sudo defaults write "$lock_plist" "DesktopPicture" "$persistent_image" >/dev/null 2>&1; then
        print_warn "Failed to set login window background via defaults"
    fi
    
    # Target user-specific lock screen cache.
    print_info "Applying lockscreen cache for active user..."
    
    local current_user
    current_user="$(stat -f%Su /dev/console 2>/dev/null || whoami)"
    
    if [[ -n "$current_user" && "$current_user" != "root" ]]; then
        if apply_lockscreen_cache_for_user "$current_user" "$persistent_image"; then
            print_info "Lockscreen cache updated for user: $current_user"
        else
            print_warn "Could not update lockscreen cache for $current_user"
        fi

        local set_wallpaper="${LOCKSCREEN_SET_WALLPAPER:-0}"

        if [[ "$set_wallpaper" == "1" ]]; then
            print_info "LOCKSCREEN_SET_WALLPAPER=1 provided; applying desktop wallpaper too..."
            if apply_wallpaper_for_user "$current_user" "$persistent_image"; then
                print_info "Wallpaper updated for user: $current_user"
            else
                print_warn "Could not update wallpaper in GUI session for $current_user"
            fi
        else
            print_info "Desktop wallpaper unchanged (lockscreen-only mode)."
        fi
    fi

    rm -f "$image_file"
    print_info "Best-effort lock-screen/loginwindow update saved. It applies on next lock screen/reboot without logging out current users."
    print_ok "Lockscreen/loginwindow update configured"
    return 0
}

# Apply lockscreen replacement for SIP-disabled systems (OCLP)
_apply_lockscreen_sip_disabled() {
    local image_file="$1"
    
    print_info "Replacing lockscreen image (SIP disabled)..."
    
    # Copy to standard macOS lockscreen locations (works Monterey-Sequoia)
    local lock_dirs=(
        "/Library/Caches/com.apple.loginwindow"
        "/var/db/loginwindow"
    )
    
    for dir in "${lock_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            sudo cp "$image_file" "$dir/lockscreen.png" 2>/dev/null && \
            sudo chmod 644 "$dir/lockscreen.png" 2>/dev/null || true
        fi
    done
    
    # Set system-wide lockscreen via com.apple.loginwindow defaults
    sudo defaults write /Library/Preferences/com.apple.loginwindow \
        "DesktopPicture" "$image_file" 2>/dev/null || true
    
    # Set for macOS login/lock screen (Monterey+)
    sudo defaults write /Library/Preferences/com.apple.loginwindow \
        "LockScreenImage" "$image_file" 2>/dev/null || true
    
    print_ok "Lockscreen replacement applied (SIP disabled)"
}

# MDM profile approach for loginwindow policy (no image payload key)
create_lockscreen_mdm_profile() {
    local image_url="${LOCKSCREEN_IMAGE_URL:-https://wall.tasw.qzz.io/mac.png}"
    local profile_id="com.lab.lockscreen.background"
    local profile_file="/tmp/${profile_id}.mobileconfig"
    local profile_uuid="A7B2C3D4-E5F6-47G8-H9I0-J1K2L3M4N5O6"
    
    print_info "Creating loginwindow policy MDM profile for Monterey-Sequoia..."
    
    # Create MDM profile that sets login window properties
    cat > "$profile_file" <<'MDMEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PayloadContent</key>
    <array>
        <dict>
            <key>PayloadType</key>
            <string>com.apple.ManagedClient.preferences</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
            <key>PayloadIdentifier</key>
            <string>com.lab.lockscreen.background.payload</string>
            <key>PayloadUUID</key>
            <string>PAYLOAD_UUID_HERE</string>
            <key>PayloadDisplayName</key>
            <string>Login Window Policy</string>
            <key>PayloadEnabled</key>
            <true/>
            <key>PayloadOrganization</key>
            <string>Lab</string>
            
            <key>com.apple.loginwindow</key>
            <dict>
                <key>Forced</key>
                <array>
                    <dict>
                        <key>mcx_preference_settings</key>
                        <dict>
                            <key>LoginwindowText</key>
                            <string>Lab System</string>
                            <key>SHOWFULLNAME</key>
                            <false/>
                            <key>DisableConsoleAccess</key>
                            <false/>
                        </dict>
                    </dict>
                </array>
            </dict>
        </dict>
    </array>
    
    <key>PayloadDisplayName</key>
    <string>Lab Login Window Configuration</string>
    <key>PayloadIdentifier</key>
    <string>com.lab.lockscreen.background</string>
    <key>PayloadRemovalDisallowed</key>
    <false/>
    <key>PayloadScope</key>
    <string>System</string>
    <key>PayloadType</key>
    <string>Configuration</string>
    <key>PayloadUUID</key>
    <string>PROFILE_UUID_HERE</string>
    <key>PayloadVersion</key>
    <integer>1</integer>
</dict>
</plist>
MDMEOF

    print_info "MDM profile created at $profile_file"
    print_info "To enroll: sudo profiles install -type configuration -path $profile_file"
    print_ok "Loginwindow policy MDM profile ready"
    return 0
}
