#!/bin/bash
# Builds the prebuilt downloads that .github/workflows/release.yml attaches to a GitHub Release. Needs no
# Apple account and no signing identity, so it runs on GitHub's free macOS runners as well as on your Mac.
#   tools/scripts/package.sh [output folder]      (default: dist/package)
# Writes:
#   - Clamshell.ipa       the iPhone app (and its widget), UNSIGNED. AltStore or SideStore signs it with the
#                         user's own free Apple Account when installing (docs/SETUP.md › Install without building).
#   - ClamshellHost.zip   the Mac host, ad-hoc signed and not notarized (first launch: Open Anyway).
#   - SHA256SUMS.txt      checksums of both.
# For your own devices, tools/scripts/release.sh (signed with your account) is still the better build.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:-$ROOT/dist/package}"
DERIVED="$ROOT/build/package"

fail() { printf '\n✗ %s\n' "$*"; exit 1; }
command -v xcodebuild >/dev/null || fail "Xcode isn't installed."
command -v xcodegen >/dev/null || fail "xcodegen is missing: brew install xcodegen"
xcodebuild -version | paste -sd ' ' -

# The same identifiers for every download, whatever a local mac-host/Config/Local.xcconfig says, and no team:
# these builds aren't signed by anyone. AltStore/SideStore give the phone app the user's own team.
COMMON=(CLAMSHELL_BUNDLE_PREFIX=dev.clamshell.local DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=)

step() { printf '\n== %s\n' "$*"; }
LOG="$DERIVED/build.log"
build() {
    mkdir -p "$DERIVED"
    xcodebuild "$@" build >>"$LOG" 2>&1 || { tail -40 "$LOG"; fail "build failed, full log: $LOG"; }
}

rm -rf "$DERIVED"; mkdir -p "$OUT" "$DERIVED"
rm -f "$OUT/Clamshell.ipa" "$OUT/ClamshellHost.zip" "$OUT/SHA256SUMS.txt" "$OUT/VERSION"

step "Generating Xcode projects"
(cd "$ROOT/mac-host" && xcodegen generate --quiet)
(cd "$ROOT/ios-client" && xcodegen generate --quiet)

step "Building the iPhone app (Release, unsigned)"
build -project "$ROOT/ios-client/Clamshell.xcodeproj" -scheme Clamshell -configuration Release \
      -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED/ios" \
      "${COMMON[@]}" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=
IOS_APP="$DERIVED/ios/Build/Products/Release-iphoneos/Clamshell.app"
[[ -d "$IOS_APP/PlugIns/ClamshellWidget.appex" ]] || fail "the widget extension is missing from $IOS_APP"
# An .ipa is Payload/<App>.app, zipped. -y keeps symlinks as symlinks.
STAGE="$DERIVED/ipa"; mkdir -p "$STAGE/Payload"
ditto "$IOS_APP" "$STAGE/Payload/Clamshell.app"
(cd "$STAGE" && zip -qry "$OUT/Clamshell.ipa" Payload)
IOS_VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$IOS_APP/Info.plist")

step "Building the Mac host (Release, ad-hoc signed)"
build -project "$ROOT/mac-host/ClamshellHost.xcodeproj" -scheme ClamshellHost -configuration Release \
      -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED/mac" ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
      "${COMMON[@]}" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- OTHER_CODE_SIGN_FLAGS=--timestamp=none \
      CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO     # no get-task-allow (debugger attach) in a download
MAC_APP="$DERIVED/mac/Build/Products/Release/ClamshellHost.app"
codesign --verify --strict --deep "$MAC_APP"
SIGNATURE=$(codesign -dv "$MAC_APP" 2>&1)
[[ "$SIGNATURE" == *$'\nSignature=adhoc'* ]] || fail "$MAC_APP isn't ad-hoc signed"
[[ "$(codesign -d --entitlements - "$MAC_APP" 2>&1)" != *get-task-allow* ]] || fail "$MAC_APP allows debugger attach"
ditto -c -k --keepParent "$MAC_APP" "$OUT/ClamshellHost.zip"
MAC_VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$MAC_APP/Contents/Info.plist")
[[ "$IOS_VERSION" == "$MAC_VERSION" ]] || fail "version mismatch: iPhone $IOS_VERSION, Mac $MAC_VERSION"

(cd "$OUT" && shasum -a 256 Clamshell.ipa ClamshellHost.zip > SHA256SUMS.txt)
echo "$MAC_VERSION" > "$OUT/VERSION"

step "Done: Clamshell $MAC_VERSION"
ls -lh "$OUT"
cat "$OUT/SHA256SUMS.txt"
