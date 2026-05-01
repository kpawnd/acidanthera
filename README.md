# Atherion

macOS lab setup automation for Intel iMacs running Sequoia 15.x. Core setup and lock screen automation target Sequoia only; scripts under scripts/miscellaneous may have their own OS support notes.

## Full setup (Sequoia)

**With git:**
```shell
git clone https://github.com/kpawnd/Atherion.git && cd Atherion && sudo bash main.sh
```

**Without git (GitHub tarball, no git required):**
```shell
curl -fsSL https://github.com/kpawnd/Atherion/archive/refs/heads/main.tar.gz | tar -xz -C /tmp && sudo bash /tmp/Atherion-main/main.sh
```

GitHub serves the entire repo as a tarball at that URL, so all scripts are present on disk and the relative `source` calls inside `main.sh` resolve correctly.

## Lock screen only

**Without git (recommended):**
```shell
curl -fsSL https://github.com/kpawnd/Atherion/archive/refs/heads/main.tar.gz | tar -xz -C /tmp && sudo bash -c 'source /tmp/Atherion-main/scripts/lib/core/ui.sh && source /tmp/Atherion-main/scripts/lib/system/lockscreen_config.sh && configure_lockscreen_background'
```

**From inside the cloned repo:**
```shell
sudo bash -c 'source scripts/lib/core/ui.sh && source scripts/lib/system/lockscreen_config.sh && configure_lockscreen_background'
```

To use a custom image URL, prepend `LOCKSCREEN_IMAGE_URL="https://..."` to either command:

```shell
curl -fsSL https://github.com/kpawnd/Atherion/archive/refs/heads/main.tar.gz | tar -xz -C /tmp && sudo bash -c 'LOCKSCREEN_IMAGE_URL="https://example.com/your-image.png" source /tmp/Atherion-main/scripts/lib/core/ui.sh && source /tmp/Atherion-main/scripts/lib/system/lockscreen_config.sh && configure_lockscreen_background'
```

To make the lock screen change take effect on Sequoia, use one of these methods:

1. Enable root with `dsenableroot`, sign in as root, and run the lock screen command.
2. Temporarily grant the target account admin privileges, run the command, then remove the privileges.

Changes take effect on the next lock screen or reboot.

## Clear Teams cache (miscellaneous)

Shortest ways to run the Teams cache script:

**With curl:**
```shell
bash -c "$(curl -fsSL https://raw.githubusercontent.com/kpawnd/Atherion/main/scripts/miscellaneous/clear_teams_cache_macos.sh)"
```

**With git:**
```shell
git clone https://github.com/kpawnd/Atherion.git && bash Atherion/scripts/miscellaneous/clear_teams_cache_macos.sh
```

Add `sudo` or flags like `--all-users` as needed.

## Local overrides

Copy `.env.example` to `.env` (gitignored) before running. Supported variables:

| Variable | Purpose |
|---|---|
| `PACKET_TRACER_DMG_URL` | Direct DMG URL for Cisco Packet Tracer (SharePoint links supported) |
| `LOCKSCREEN_IMAGE_URL` | Custom wallpaper/lock screen image URL |
| `LOCKSCREEN_REPLACE_SYSTEM` | `1` (default) replaces `/System/Library/Desktop Pictures/<release>.heic` so the cold-boot login screen actually changes. Only runs when SIP and authenticated-root are both disabled (OCLP). Set `0` to skip. |
| `LOCKSCREEN_SET_WALLPAPER` | `1` (default) sets each local user's desktop wallpaper. Set `0` to skip. |
| `NO_PROGRESS` | Set `1` to suppress the live spinner. Stage transitions print as plain log lines instead. Use when teeing output to a log or running unattended. |
| `RELEASES_REPO` | Override GitHub repo used to resolve release assets |
| `BLENDER_DMG_URL` / `BLENDER_VERSION` | Override Blender download URL and version |
