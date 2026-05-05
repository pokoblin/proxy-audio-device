#!/bin/bash
#
# uninstall.sh
#
# Removes ProxyAudioDevice.driver from /Library/Audio/Plug-Ins/HAL/ and
# restarts coreaudiod so the change takes effect.
#
# Usage:
#   ./uninstall.sh           # remove driver, restart coreaudiod
#   ./uninstall.sh --app     # also remove "Proxy Audio Device Settings.app"
#                            #   from /Applications if present
#   ./uninstall.sh --dry-run # show what would be removed, change nothing
#
# coreaudiod restart strategy mirrors rebuild-and-install.sh: try
# `launchctl kickstart` first, fall back to `sudo killall coreaudiod` (SIP
# blocks kickstart on macOS 26+ but allows signal delivery), and only
# print a highlighted manual-step prompt if both fail.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/rebuild-and-install.config"

# Pick up HAL_PLUGIN_DIR override from the install script's config if present.
HAL_PLUGIN_DIR="/Library/Audio/Plug-Ins/HAL"
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

# ---------- arg parsing ----------
REMOVE_APP=false
DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --app)     REMOVE_APP=true ;;
        --dry-run) DRY_RUN=true ;;
        -h|--help)
            sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            exit 2
            ;;
    esac
done

# ---------- find what to remove ----------
DRIVER_TARGET="$HAL_PLUGIN_DIR/ProxyAudioDevice.driver"
APP_TARGET="/Applications/Proxy Audio Device Settings.app"

removed_anything=false

run_or_print() {
    if $DRY_RUN; then
        echo "    [dry-run] would run: $*"
    else
        "$@"
    fi
}

# ---------- remove driver ----------
if [[ -d "$DRIVER_TARGET" ]]; then
    echo "==> Removing $DRIVER_TARGET (sudo required)"
    run_or_print sudo rm -rf "$DRIVER_TARGET"
    removed_anything=true
else
    echo "==> $DRIVER_TARGET not present — skipping."
fi

# ---------- remove settings app (optional) ----------
if $REMOVE_APP; then
    if [[ -d "$APP_TARGET" ]]; then
        echo "==> Removing $APP_TARGET"
        run_or_print sudo rm -rf "$APP_TARGET"
        removed_anything=true
    else
        echo "==> $APP_TARGET not present — skipping."
    fi
fi

if ! $removed_anything; then
    echo "==> Nothing was removed. Exiting."
    exit 0
fi

if $DRY_RUN; then
    echo "==> --dry-run specified, not restarting coreaudiod."
    exit 0
fi

# ---------- restart coreaudiod ----------
# See rebuild-and-install.sh for the rationale on the macOS-version matrix
# (kickstart blocked by SIP on 26+, killall blocked on 14.4–25, etc.).

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
${BOLD}${YELLOW}║${RESET}  Could not restart coreaudiod automatically. The driver bundle is   ${BOLD}${YELLOW}║${RESET}
${BOLD}${YELLOW}║${RESET}  gone from disk but coreaudiod still has it loaded in memory.       ${BOLD}${YELLOW}║${RESET}
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
