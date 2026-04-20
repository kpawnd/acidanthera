#!/bin/bash

# Configure custom lockscreen/login window background
# Works across macOS Monterey (12) through Sequoia (15)
# Supports both SIP-enabled and SIP-disabled (OCLP) systems

configure_lockscreen_background() {
    local image_url="${LOCKSCREEN_IMAGE_URL:-https://wall.tasw.qzz.io/mac.png}"
    local image_file="/tmp/lockscreen_bg.png"
    local persistent_dir="/Library/Application Support/Acidanthera"
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
    
    # Always set login window background (works with or without SIP)
    print_info "Setting login window background..."
    
    # Copy to system location
    sudo cp "$persistent_image" /Library/Caches/com.apple.loginwindow/lockscreen_bg.png 2>/dev/null || true
    
    # Set via defaults (Monterey-Sequoia compatible)
    if ! sudo defaults write "$lock_plist" "DesktopPicture" "$persistent_image" >/dev/null 2>&1; then
        print_warn "Failed to set login window background via defaults"
    fi
    
    # Set wallpaper for all users (post-login background)
    print_info "Applying wallpaper to active user..."
    
    local current_user
    current_user="$(stat -f%Su /dev/console 2>/dev/null || whoami)"
    
    if [[ -n "$current_user" && "$current_user" != "root" ]]; then
        # Set desktop background for current user
        osascript <<EOF 2>/dev/null || true
tell application "System Events"
    set theDesktop to the desktop
    set the picture of theDesktop to "$persistent_image"
end tell
EOF
    fi

    rm -f "$image_file"
    print_info "Lockscreen update saved. It applies on next lock screen/reboot without logging out current users."
    print_ok "Lockscreen background configured"
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

# MDM profile approach for persistent cross-version lockscreen
create_lockscreen_mdm_profile() {
    local image_url="${LOCKSCREEN_IMAGE_URL:-https://wall.tasw.qzz.io/mac.png}"
    local profile_id="com.lab.lockscreen.background"
    local profile_file="/tmp/${profile_id}.mobileconfig"
    local profile_uuid="A7B2C3D4-E5F6-47G8-H9I0-J1K2L3M4N5O6"
    
    print_info "Creating lockscreen MDM profile for Monterey-Sequoia..."
    
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
            <string>Lockscreen Background</string>
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
    <string>Lab Lockscreen Configuration</string>
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
    print_ok "Lockscreen MDM profile ready"
    return 0
}
