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

configure_apple_account_restrictions() {
    local profile_id="com.lab.restrictions.apple-account"
    local profile_file="/tmp/${profile_id}.mobileconfig"
    local profiles_err="/tmp/${profile_id}.err"
    local profile_uuid_payload="9E8D88F7-1E6A-4C80-BBCD-4B5C62784A10"
    local profile_uuid_root="1A2F4E5C-11A7-47E1-8A27-13C2A4CF7E50"

    print_info "Applying local Apple account and iCloud restrictions profile..."

    cat > "$profile_file" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PayloadContent</key>
    <array>
        <dict>
            <key>PayloadType</key>
            <string>com.apple.applicationaccess</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
            <key>PayloadIdentifier</key>
            <string>${profile_id}.payload</string>
            <key>PayloadUUID</key>
            <string>${profile_uuid_payload}</string>
            <key>PayloadDisplayName</key>
            <string>Lab Apple Account Restrictions</string>

            <key>allowAccountModification</key>
            <false/>
            <key>allowCloudDocumentSync</key>
            <false/>
            <key>allowCloudDesktopAndDocuments</key>
            <false/>
            <key>allowCloudKeychainSync</key>
            <false/>
            <key>allowCloudPhotoLibrary</key>
            <false/>
            <key>allowCloudMail</key>
            <false/>
            <key>allowCloudAddressBook</key>
            <false/>
            <key>allowCloudCalendar</key>
            <false/>
            <key>allowCloudReminders</key>
            <false/>
            <key>allowCloudBookmarks</key>
            <false/>
        </dict>
    </array>
    <key>PayloadDisplayName</key>
    <string>Lab Apple Restrictions</string>
    <key>PayloadIdentifier</key>
    <string>${profile_id}</string>
    <key>PayloadOrganization</key>
    <string>Lab</string>
    <key>PayloadRemovalDisallowed</key>
    <false/>
    <key>PayloadScope</key>
    <string>System</string>
    <key>PayloadType</key>
    <string>Configuration</string>
    <key>PayloadUUID</key>
    <string>${profile_uuid_root}</string>
    <key>PayloadVersion</key>
    <integer>1</integer>
</dict>
</plist>
EOF

    if ! plutil -lint "$profile_file" >/dev/null 2>&1; then
        print_warn "Generated restrictions profile is invalid XML/plist."
        rm -f "$profile_file" "$profiles_err" >/dev/null 2>&1 || true
        return 1
    fi

    sudo profiles remove -identifier "$profile_id" >/dev/null 2>&1 || true
    if ! sudo profiles -I -F "$profile_file" > /dev/null 2>"$profiles_err"; then
        if ! sudo profiles install -type configuration -path "$profile_file" > /dev/null 2>>"$profiles_err"; then
            print_warn "Failed to install Apple account restrictions profile."
            if [[ -s "$profiles_err" ]]; then
                print_warn "profiles output: $(tail -n 1 "$profiles_err")"
            fi
            rm -f "$profile_file" "$profiles_err" >/dev/null 2>&1 || true
            return 1
        fi
    fi

    rm -f "$profile_file" "$profiles_err" >/dev/null 2>&1 || true
    print_ok "Apple account/iCloud restrictions profile installed."
    return 0
}
