#!/bin/bash
# Checks the Clamshell Microphone driver without installing it: loads the built bundle in a test process and
# runs mac-host/Driver/Tests/driver-test.c against it. Build the host first (release.sh, or Xcode).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN=""
for p in "$ROOT"/mac-host/build/*/Build/Products/*/ClamshellHost.app/Contents/PlugIns/ClamshellMicrophone.driver/Contents/MacOS/ClamshellMicrophone; do
    [[ -f "$p" ]] && BIN="$p"
done
[[ -n "$BIN" ]] || { echo "Build the Mac host first: tools/scripts/release.sh --no-install"; exit 1; }
OUT="$(mktemp -d)/driver-test"
clang -Wall -Wextra -Werror -o "$OUT" "$ROOT/mac-host/Driver/Tests/driver-test.c" -framework CoreAudio -framework CoreFoundation
"$OUT" "$BIN"
