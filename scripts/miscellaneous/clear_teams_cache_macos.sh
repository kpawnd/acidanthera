#!/bin/bash

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

# Classic Teams first, followed by Microsoft's newer containers
TEAMS_CACHE_PATHS=(
	"Library/Application Support/Microsoft/Teams"
	"Library/Group Containers/UBF8T346G9.com.microsoft.teams"
	"Library/Containers/com.microsoft.teams2"
)

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)" || SCRIPT_DIR=""
if [[ -n "$SCRIPT_DIR" && -r "$SCRIPT_DIR/scripts/lib/core/ui.sh" ]]; then
	# shellcheck disable=SC1090
	source "$SCRIPT_DIR/scripts/lib/core/ui.sh"
else
	print_info() { printf '[INFO] %s\n' "$*"; }
	print_warn() { printf '[WARN] %s\n' "$*" >&2; }
	print_err() { printf '[ERROR] %s\n' "$*" >&2; }
	print_ok() { printf '[ OK ] %s\n' "$*"; }
fi


require_root() {
	if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
		print_err "This script must be run as root. Use sudo."
		exit 1
	fi
}

console_user() {
	local user
	user="$(/usr/bin/stat -f '%Su' /dev/console 2>/dev/null || true)"
	if [[ -z "$user" || "$user" == "root" || "$user" == "_mbsetupuser" ]]; then
		if [[ -n "${SUDO_USER:-}" && "${SUDO_USER:-}" != "root" ]]; then
			user="$SUDO_USER"
		else
			return 1
		fi
	fi
	printf '%s\n' "$user"
}

home_for_user() {
	local user="$1" home
	home="$(/usr/bin/dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | /usr/bin/sed 's/^NFSHomeDirectory: //' || true)"
	if [[ -z "$home" || ! -d "$home" ]]; then
		home="/Users/$user"
	fi
	[[ -n "$home" && -d "$home" ]] || return 1
	printf '%s\n' "$home"
}

list_local_users() {
	local home name
	for home in /Users/*; do
		[[ -d "$home" ]] || continue
		name="$(basename "$home")"
		case "$name" in
			Shared|Guest|Deleted\ Users) continue ;;
		esac
		if /usr/bin/id "$name" >/dev/null 2>&1; then
			printf '%s\n' "$name"
		fi
	done
}

quit_teams_for_user() {
	local user="$1" uid
	uid="$(id -u "$user" 2>/dev/null || true)"
	[[ -n "$uid" ]] || return 0

	print_info "Attempting to quit Teams for user '$user' (uid $uid)."

	# Try to gracefully quit via AppleScript in the user's session (best-effort)
	/usr/bin/su -l "$user" -c "/usr/bin/osascript -e 'tell application id \"com.microsoft.teams2\" to quit'" >/dev/null 2>&1 || true
	/usr/bin/su -l "$user" -c "/usr/bin/osascript -e 'tell application id \"com.microsoft.teams\" to quit'" >/dev/null 2>&1 || true

	# Force-kill any remaining Teams processes for that UID
	/usr/bin/pkill -u "$uid" -f 'Microsoft Teams|MSTeams|Teams' >/dev/null 2>&1 || true
	sleep 1
}

remove_path() {
	local path="$1" home="$2"

	# safety: only remove paths under the user's home
	case "$path" in
		"$home"/*) ;;
		*)
			print_warn "Skipping path outside of home: $path"
			return 0
			;;
	esac

	if [[ ! -e "$path" ]]; then
		print_info "Not present: $path"
		return 0
	fi

	/bin/rm -rf -- "$path" >/dev/null 2>&1 || {
		print_warn "Failed to remove: $path"
		return 1
	}
	print_ok "Removed: $path"
}

clear_for_user() {
	local user="$1" home
	home="$(home_for_user "$user")" || {
		print_warn "Could not resolve home for '$user'; skipping."
		return 0
	}

	print_info "Clearing Teams cache for user '$user' at $home."

	quit_teams_for_user "$user"

	for rel in "${TEAMS_CACHE_PATHS[@]}"; do
		remove_path "$home/$rel" "$home" || true
	done
}

main() {
	require_root

	# Run for all local users by default (force behavior)
	local user
	while IFS= read -r user; do
		clear_for_user "$user"
	done < <(list_local_users)

	print_ok "Teams cache clear complete. Start Teams again and sign in fresh."
}

main "$@"

