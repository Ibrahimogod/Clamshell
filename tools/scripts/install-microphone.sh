#!/bin/bash
# Installs the Clamshell Microphone (the phone's mic as a Mac input device). Run it yourself: it uses sudo,
# because macOS only loads audio drivers from /Library/Audio/Plug-Ins/HAL, which belongs to root.
#   tools/scripts/install-microphone.sh             install (or update) from the installed host app
#   tools/scripts/install-microphone.sh --uninstall remove it
# Both restart Core Audio, so sound on the Mac cuts out for a second or two.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEST="/Library/Audio/Plug-Ins/HAL/ClamshellMicrophone.driver"

restart_audio() {
    echo "Restarting Core Audio…"
    sudo killall coreaudiod 2>/dev/null || true
}

if [[ "${1:-}" == "--uninstall" ]]; then
    if [[ -d "$DEST" ]]; then
        sudo rm -rf "$DEST"
        restart_audio
        echo "Removed the Clamshell Microphone."
    else
        echo "The Clamshell Microphone isn't installed."
    fi
    exit 0
fi

SRC=""
if [[ -d /Applications/ClamshellHost.app/Contents/PlugIns/ClamshellMicrophone.driver ]]; then
    SRC=/Applications/ClamshellHost.app/Contents/PlugIns/ClamshellMicrophone.driver
else
    for p in "$ROOT"/mac-host/build/*/Build/Products/Release/ClamshellHost.app/Contents/PlugIns/ClamshellMicrophone.driver; do
        [[ -d "$p" ]] && SRC="$p"
    done
fi
[[ -n "$SRC" ]] || { echo "No built driver found. Build the host first: tools/scripts/release.sh"; exit 1; }

echo "Installing $SRC"
echo "      → $DEST (asks for your password)"
sudo rm -rf "$DEST"
sudo ditto "$SRC" "$DEST"
sudo chown -R root:wheel "$DEST"
restart_audio
sleep 2
if system_profiler SPAudioDataType 2>/dev/null | grep -q "Clamshell Microphone"; then
    echo "Done: \"Clamshell Microphone\" is in System Settings → Sound → Input."
else
    echo "Installed, but Core Audio hasn't listed it yet. Wait a few seconds, or log out and back in."
fi
