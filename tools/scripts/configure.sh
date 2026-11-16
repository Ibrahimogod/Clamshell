#!/bin/bash
# One-time setup: writes mac-host/Config/Local.xcconfig, the personal signing config both apps build with
# (your Apple team ID and a bundle-ID prefix). The file is gitignored.
#
#   tools/scripts/configure.sh                         find your team from the Apple Development certificate
#   tools/scripts/configure.sh <TEAM_ID> [<prefix>]    use these
#   options: --print (show what would be written)  --force (replace an existing Local.xcconfig)
#
# No certificate yet? Open Xcode › Settings › Accounts, add your Apple Account (a free one works), select the
# team, Manage Certificates… › + › Apple Development. Then run this again.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/mac-host/Config/Local.xcconfig"
PRINT=0; FORCE=0; ARGS=()
for a in "$@"; do
    case "$a" in
        --print) PRINT=1 ;;
        --force) FORCE=1 ;;
        -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
        *) ARGS+=("$a") ;;
    esac
done

TEAM="${ARGS[0]:-}"
if [[ -z "$TEAM" ]]; then
    # Team IDs are the OU of each "Apple Development" signing certificate in the login keychain.
    TEAMS=$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: .*\)"$/\1/p' | sort -u |
        while IFS= read -r name; do
            security find-certificate -c "$name" -p 2>/dev/null | openssl x509 -noout -subject -nameopt multiline 2>/dev/null |
                sed -n 's/^ *organizationalUnitName *= *\([A-Z0-9]\{10\}\)$/\1/p'
        done | sort -u)
    COUNT=$(printf '%s' "$TEAMS" | grep -c . || true)
    if [[ "$COUNT" == 0 ]]; then
        echo "No Apple Development certificate found."
        echo "Open Xcode › Settings › Accounts, add your Apple Account, select the team, then"
        echo "Manage Certificates… › + › Apple Development. Run this again afterwards,"
        echo "or pass your team ID: tools/scripts/configure.sh <TEAM_ID>"
        exit 1
    elif [[ "$COUNT" -gt 1 ]]; then
        echo "Several teams have certificates on this Mac:"; printf '  %s\n' $TEAMS
        echo "Pick one: tools/scripts/configure.sh <TEAM_ID> [<bundle prefix>]"
        exit 1
    fi
    TEAM="$TEAMS"
fi
if ! [[ "$TEAM" =~ ^[A-Z0-9]{10}$ ]]; then
    echo "\"$TEAM\" doesn't look like a team ID (10 letters and digits, developer.apple.com › Account › Membership)."
    exit 1
fi

# A prefix of your own; Apple refuses an ID someone else has registered, so pass another one if that happens.
USERPART=$(id -un | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')
PREFIX="${ARGS[1]:-dev.${USERPART:-me}.clamshell}"
if ! [[ "$PREFIX" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then
    echo "\"$PREFIX\" isn't a reverse-DNS prefix like com.yourname.clamshell."
    exit 1
fi

CONTENT="// Personal signing config (gitignored), written by tools/scripts/configure.sh. Used by both apps.
DEVELOPMENT_TEAM = $TEAM
// The apps become <prefix>.host and <prefix>.client.
CLAMSHELL_BUNDLE_PREFIX = $PREFIX"

if [[ $PRINT == 1 ]]; then echo "$CONTENT"; exit 0; fi
if [[ -f "$OUT" && $FORCE == 0 ]]; then
    echo "$OUT already exists:"; sed 's/^/  /' "$OUT"
    echo "Keep it, or run again with --force to replace it."
    exit 0
fi
printf '%s\n' "$CONTENT" > "$OUT"
echo "Wrote $OUT (team $TEAM, apps $PREFIX.host and $PREFIX.client)."
echo "Next: tools/scripts/release.sh"
