#!/bin/bash
# Release builds of both apps, signed with your own Apple account (mac-host/Config/Local.xcconfig).
#   - Mac:    ClamshellHost.app → /Applications, plus dist/ClamshellHost-<version>.zip
#   - iPhone: Clamshell.app → installed on the connected iPhone (USB or the same Wi-Fi), if there is one
#   tools/scripts/release.sh [--no-install]      (CLAMSHELL_DEVICE=<name or UDID> picks the phone; default: a Duo)
# First time: tools/scripts/configure.sh writes that config. Signed with an "Apple Development" certificate:
# fine for your own Mac and phone. Handing the Mac app to someone else needs Developer ID + notarization
# (paid Apple Developer Program, docs/app-store.md).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALL=1; [[ "${1:-}" == "--no-install" ]] && INSTALL=0

# Preflight: say exactly what's missing instead of failing deep inside xcodebuild.
fail() { printf '\n✗ %s\n' "$*"; exit 1; }
command -v xcodebuild >/dev/null || fail "Xcode isn't installed: get it from the App Store, open it once, and accept the licence."
xcodebuild -version >/dev/null 2>&1 || fail "Xcode's command-line tools aren't set up: run  sudo xcode-select -s /Applications/Xcode.app  and open Xcode once."
command -v xcodegen >/dev/null || fail "xcodegen is missing: brew install xcodegen  (Homebrew: https://brew.sh)"
LOCAL="$ROOT/mac-host/Config/Local.xcconfig"
[[ -f "$LOCAL" ]] || fail "No signing config yet: run  tools/scripts/configure.sh  first (docs/SETUP.md §1)."
TEAM=$(sed -n 's/^ *DEVELOPMENT_TEAM *= *\([A-Z0-9]*\).*/\1/p' "$LOCAL" | tail -1)
[[ -n "$TEAM" && "$TEAM" != "ABCDE12345" ]] || fail "DEVELOPMENT_TEAM isn't set in $LOCAL: run  tools/scripts/configure.sh --force"

DIST="$ROOT/dist"; mkdir -p "$DIST"
LOG="$DIST/build.log"; : > "$LOG"

step() { printf '\n== %s\n' "$*"; }
build() { xcodebuild "$@" -allowProvisioningUpdates build >>"$LOG" 2>&1 || { tail -30 "$LOG"; echo "build failed, full log: $LOG"; exit 1; }; }

step "Generating Xcode projects"
(cd "$ROOT/mac-host" && xcodegen generate --quiet)
(cd "$ROOT/ios-client" && xcodegen generate --quiet)

step "Building the Mac host (Release)"
build -project "$ROOT/mac-host/ClamshellHost.xcodeproj" -scheme ClamshellHost -configuration Release \
      -derivedDataPath "$ROOT/mac-host/build/release"
APP="$ROOT/mac-host/build/release/Build/Products/Release/ClamshellHost.app"
codesign --verify --strict --deep "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")
rm -f "$DIST/ClamshellHost-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$DIST/ClamshellHost-$VERSION.zip"
echo "signed by: $(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
echo "zip: $DIST/ClamshellHost-$VERSION.zip"

step "Building the iPhone app (Release)"
build -project "$ROOT/ios-client/Clamshell.xcodeproj" -scheme Clamshell -configuration Release \
      -destination 'generic/platform=iOS' -derivedDataPath "$ROOT/ios-client/build/release"
IPA_APP="$ROOT/ios-client/build/release/Build/Products/Release-iphoneos/Clamshell.app"
# The app and its widget each carry a profile; the earliest one decides when the app stops opening.
EXPIRES=$(for p in "$IPA_APP"/embedded.mobileprovision "$IPA_APP"/PlugIns/*.appex/embedded.mobileprovision; do
    [[ -f "$p" ]] && security cms -D -i "$p" 2>/dev/null | plutil -extract ExpirationDate raw - 2>/dev/null
done | sort | head -1)
EXPIRES=${EXPIRES:-?}
echo "app: $IPA_APP"
echo "provisioning profile expires: $EXPIRES (after that the app won't open until you run this again)"

[[ $INSTALL == 1 ]] || { echo; echo "Built $VERSION ($BUILD). Not installed (--no-install)."; exit 0; }

step "Installing the Mac host in /Applications"
osascript -e 'tell application id "'"$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist")"'" to quit' 2>/dev/null || true
sleep 1; pkill -x ClamshellHost 2>/dev/null || true; sleep 1
rm -rf /Applications/ClamshellHost.app
ditto "$APP" /Applications/ClamshellHost.app
open /Applications/ClamshellHost.app
echo "running: /Applications/ClamshellHost.app (log: ~/Library/Logs/Clamshell/host.log)"

step "Installing on the iPhone"
DEVICES="$DIST/devices.json"
if xcrun devicectl --timeout 20 list devices --json-output "$DEVICES" >/dev/null 2>&1; then
    UDID=$(python3 -c 'import json,sys,os
d=json.load(open(sys.argv[1]))["result"]["devices"]
want=os.environ.get("CLAMSHELL_DEVICE","")
def caps(x): return {f["featureIdentifier"] for f in x.get("capabilities",[])}
# A named phone is used even when it reports "disconnected": that only means no tunnel is open yet, and
# the install opens one. devicectl lists no capabilities for such a phone, so only its pairing is checked.
# Otherwise only phones with a live connection that can take an app.
ok=[x for x in d if x.get("connectionProperties",{}).get("pairingState")=="paired"]
if want: ok=[x for x in ok if want in (x["hardwareProperties"].get("udid",""), x.get("deviceProperties",{}).get("name",""))]
else: ok=[x for x in ok if x.get("connectionProperties",{}).get("tunnelState")=="connected" and "com.apple.coredevice.feature.installapp" in caps(x)]
ok.sort(key=lambda x: x["hardwareProperties"].get("productType")!="iPhone19,4")   # an iPhone Duo first
for x in ok: print("  found:", x.get("deviceProperties",{}).get("name","?"), x["hardwareProperties"].get("productType"), file=sys.stderr)
print(ok[0]["hardwareProperties"]["udid"] if ok else "")' "$DEVICES")
    if [[ -n "$UDID" ]]; then
        xcrun devicectl --timeout 120 device install app --device "$UDID" "$IPA_APP" >>"$LOG" 2>&1 \
            && echo "installed on $UDID" || echo "install failed (is the phone unlocked?), see $LOG"
    else
        echo "no iPhone connected: connect it and run this again, or install $IPA_APP from Xcode"
    fi
fi
rm -f "$DEVICES"
echo; echo "Done: Clamshell $VERSION ($BUILD)."
