#!/bin/bash
#
# install.sh
#
# Installs the pre-built ProxyAudioDevice.driver and the Settings app from
# this folder onto the local machine, and restarts coreaudiod so the
# driver is picked up.
#
# This is the end-user counterpart to rebuild-and-install.sh: it expects
# already-signed bundles to live next to the script (the layout produced
# by extracting the release zip), and does NOT compile anything.
#
# Usage:
#   ./install.sh              # install driver + Settings.app, restart coreaudiod
#   ./install.sh --no-app     # install driver only (skip Settings.app)
#   ./install.sh --dry-run    # show what would happen, change nothing
#
# coreaudiod restart strategy mirrors uninstall.sh: try `launchctl
# kickstart` first, fall back to `sudo killall coreaudiod` (SIP blocks
# kickstart on macOS 26+ but allows signal delivery), and only print a
# highlighted manual-step prompt if both fail.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HAL_PLUGIN_DIR="/Library/Audio/Plug-Ins/HAL"
APPLICATIONS_DIR="/Applications"

DRIVER_SRC="$SCRIPT_DIR/ProxyAudioDevice.driver"
APP_SRC="$SCRIPT_DIR/Proxy Audio Device Settings.app"

# ---------- arg parsing ----------
INSTALL_APP=true
DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --no-app)  INSTALL_APP=false ;;
        --dry-run) DRY_RUN=true ;;
        -h|--help)
            sed -n '3,18p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            exit 2
            ;;
    esac
done

run_or_print() {
    if $DRY_RUN; then
        echo "    [dry-run] would run: $*"
    else
        "$@"
    fi
}

# ---------- preflight ----------
if [[ ! -d "$DRIVER_SRC" ]]; then
    echo "ERROR: cannot find $DRIVER_SRC" >&2
    echo "       Run this script from the folder produced by extracting the release zip." >&2
    exit 1
fi

if $INSTALL_APP && [[ ! -d "$APP_SRC" ]]; then
    echo "WARNING: Settings.app not found at $APP_SRC — driver will install but app will be skipped."
    INSTALL_APP=false
fi

# Verify the driver bundle's signature before installing it. Catches
# corrupted downloads, tampered zips, and stripped extended attributes.
if ! codesign -v --strict --deep "$DRIVER_SRC" 2>/dev/null; then
    echo "ERROR: signature verification failed for $DRIVER_SRC" >&2
    echo "       The bundle may be corrupted. Re-download the release zip." >&2
    exit 1
fi
if $INSTALL_APP && ! codesign -v --strict --deep "$APP_SRC" 2>/dev/null; then
    echo "ERROR: signature verification failed for $APP_SRC" >&2
    exit 1
fi

# ---------- install driver ----------
DRIVER_TARGET="$HAL_PLUGIN_DIR/ProxyAudioDevice.driver"

echo "==> Installing $DRIVER_TARGET (sudo required)"
# Strip Gatekeeper quarantine on the source so the installed copy isn't
# flagged. (Bundles signed with Developer ID still load, but stripping
# avoids first-launch warnings from the Settings app and cleaner logs
# from coreaudiod.)
run_or_print sudo xattr -dr com.apple.quarantine "$DRIVER_SRC" 2>/dev/null || true

# Make sure the destination directory exists; on a fresh macOS install it
# may not.
run_or_print sudo mkdir -p "$HAL_PLUGIN_DIR"

run_or_print sudo rm -rf "$DRIVER_TARGET"
run_or_print sudo cp -R "$DRIVER_SRC" "$HAL_PLUGIN_DIR/"
run_or_print sudo chown -R root:wheel "$DRIVER_TARGET"

# ---------- install app ----------
if $INSTALL_APP; then
    APP_TARGET="$APPLICATIONS_DIR/Proxy Audio Device Settings.app"
    echo "==> Installing $APP_TARGET"
    run_or_print sudo xattr -dr com.apple.quarantine "$APP_SRC" 2>/dev/null || true
    run_or_print sudo rm -rf "$APP_TARGET"
    run_or_print sudo cp -R "$APP_SRC" "$APPLICATIONS_DIR/"
fi

if $DRY_RUN; then
    echo "==> --dry-run specified, not restarting coreaudiod."
    exit 0
fi

# ---------- restart coreaudiod ----------
# See uninstall.sh / rebuild-and-install.sh for the macOS-version matrix.
if [[ -t 1 ]]; then
    BOLD=$'\033[1m'
    YELLOW=$'\033[33m'
    RED=$'\033[31m'
    RESET=$'\033[0m'
else
    BOLD=""; YELLOW=""; RED=""; RESET=""
fi

echo "==> Restarting coreaudiod"
restart_ok=false

if sudo launchctl kickstart -kp system/com.apple.audio.coreaudiod 2>/dev/null; then
    echo "    coreaudiod restarted via launchctl kickstart."
    restart_ok=true
elif sudo killall coreaudiod 2>/dev/null; then
    echo "    coreaudiod restarted via killall (launchctl kickstart was blocked,"
    echo "    likely due to SIP on macOS 26+)."
    restart_ok=true
fi

if ! $restart_ok; then
    cat <<EOF

${BOLD}${YELLOW}╔══════════════════════════════════════════════════════════════════════╗${RESET}
${BOLD}${YELLOW}║${RESET}  ${BOLD}${RED}MANUAL STEP REQUIRED${RESET}                                                ${BOLD}${YELLOW}║${RESET}
${BOLD}${YELLOW}╠══════════════════════════════════════════════════════════════════════╣${RESET}
${BOLD}${YELLOW}║${RESET}  Could not restart coreaudiod automatically. The new .driver is     ${BOLD}${YELLOW}║${RESET}
${BOLD}${YELLOW}║${RESET}  installed but coreaudiod is still using the old one in memory.     ${BOLD}${YELLOW}║${RESET}
${BOLD}${YELLOW}║${RESET}                                                                      ${BOLD}${YELLOW}║${RESET}
${BOLD}${YELLOW}║${RESET}  Run this command manually to finish:                                ${BOLD}${YELLOW}║${RESET}
${BOLD}${YELLOW}║${RESET}                                                                      ${BOLD}${YELLOW}║${RESET}
${BOLD}${YELLOW}║${RESET}      ${BOLD}sudo killall coreaudiod${RESET}                                       ${BOLD}${YELLOW}║${RESET}
${BOLD}${YELLOW}║${RESET}                                                                      ${BOLD}${YELLOW}║${RESET}
${BOLD}${YELLOW}║${RESET}  If that also fails: log out and back in, or reboot.                ${BOLD}${YELLOW}║${RESET}
${BOLD}${YELLOW}╚══════════════════════════════════════════════════════════════════════╝${RESET}

EOF
fi

echo "==> Done."
echo "    Installed driver: $DRIVER_TARGET"
$INSTALL_APP && echo "    Installed app:    $APP_TARGET"
echo "    Open the Proxy Audio Device Settings app to configure the device."
