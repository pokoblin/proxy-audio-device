#!/bin/bash
#
# rebuild-and-install.sh
#
# Rebuilds the ProxyAudioDevice HAL plugin with your own signing identity,
# installs it into /Library/Audio/Plug-Ins/HAL/, and restarts coreaudiod.
#
# Configuration is read from `rebuild-and-install.config` next to this script.
# That file is gitignored — copy `rebuild-and-install.config.template` to it
# and fill in your team / signing identity before first run.
#
# Usage:
#   ./rebuild-and-install.sh            # build + install + restart coreaudiod
#   ./rebuild-and-install.sh --build    # build only, no install
#   ./rebuild-and-install.sh --no-clean # skip `clean` (incremental build)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/rebuild-and-install.config"
TEMPLATE_FILE="$SCRIPT_DIR/rebuild-and-install.config.template"
PROJECT_FILE="$SCRIPT_DIR/proxyAudioDevice.xcodeproj"

# ---------- arg parsing ----------
BUILD_ONLY=false
DO_CLEAN=true
for arg in "$@"; do
    case "$arg" in
        --build|--build-only) BUILD_ONLY=true ;;
        --no-clean)           DO_CLEAN=false ;;
        -h|--help)
            sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            exit 2
            ;;
    esac
done

# ---------- load config ----------
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: $CONFIG_FILE not found." >&2
    if [[ -f "$TEMPLATE_FILE" ]]; then
        echo "       Copy the template and fill in your values:" >&2
        echo "         cp \"$TEMPLATE_FILE\" \"$CONFIG_FILE\"" >&2
    fi
    exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

# Defaults for anything not set in the config.
CONFIGURATION="${CONFIGURATION:-Release}"
HAL_PLUGIN_DIR="${HAL_PLUGIN_DIR:-/Library/Audio/Plug-Ins/HAL}"

# ---------- validate config ----------
missing=()
[[ -z "${DEVELOPMENT_TEAM:-}"    ]] && missing+=("DEVELOPMENT_TEAM")
[[ -z "${CODE_SIGN_IDENTITY:-}"  ]] && missing+=("CODE_SIGN_IDENTITY")
if (( ${#missing[@]} > 0 )); then
    echo "ERROR: missing required value(s) in $CONFIG_FILE: ${missing[*]}" >&2
    echo "       See $TEMPLATE_FILE for documentation." >&2
    exit 1
fi

if [[ ! -d "$PROJECT_FILE" ]]; then
    echo "ERROR: cannot find $PROJECT_FILE" >&2
    exit 1
fi

# Sanity-check that the requested signing identity actually exists in the
# keychain — saves a confusing xcodebuild failure later.
if ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "$CODE_SIGN_IDENTITY"; then
    echo "ERROR: signing identity not found in keychain:" >&2
    echo "       \"$CODE_SIGN_IDENTITY\"" >&2
    echo "       Available identities:" >&2
    security find-identity -v -p codesigning | sed 's/^/         /' >&2
    exit 1
fi

# ---------- build ----------
echo "==> Building ProxyAudioDevice ($CONFIGURATION) with team $DEVELOPMENT_TEAM"

build_action=("build")
$DO_CLEAN && build_action=("clean" "build")

xcodebuild \
    -project "$PROJECT_FILE" \
    -target ProxyAudioDevice \
    -configuration "$CONFIGURATION" \
    "${build_action[@]}" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY" \
    CODE_SIGN_STYLE=Manual \
    ONLY_ACTIVE_ARCH=NO \
    | tail -100

BUILT_DRIVER="$SCRIPT_DIR/build/$CONFIGURATION/ProxyAudioDevice.driver"
if [[ ! -d "$BUILT_DRIVER" ]]; then
    echo "ERROR: build appears to have succeeded but $BUILT_DRIVER is missing." >&2
    exit 1
fi

echo "==> Verifying signature"
codesign -dvvv "$BUILT_DRIVER" 2>&1 | grep -E "Authority|Identifier|Format" || true

if $BUILD_ONLY; then
    echo "==> --build specified, skipping install."
    echo "    Built: $BUILT_DRIVER"
    exit 0
fi

# ---------- install ----------
TARGET="$HAL_PLUGIN_DIR/ProxyAudioDevice.driver"

echo "==> Installing to $TARGET (sudo required)"
sudo rm -rf "$TARGET"
sudo cp -R "$BUILT_DRIVER" "$HAL_PLUGIN_DIR/"
sudo chown -R root:wheel "$TARGET"

# ---------- restart coreaudiod ----------
echo "==> Restarting coreaudiod"
# macOS 14.4+ requires launchctl kickstart; `killall coreaudiod` no longer
# works because coreaudiod runs in a protected launchd domain.
sudo launchctl kickstart -kp system/com.apple.audio.coreaudiod

echo "==> Done."
echo "    Installed: $TARGET"
echo "    Watch logs with:"
echo "      log stream --predicate 'eventMessage CONTAINS \"ProxyAudio\"' --info"
