#!/bin/bash
# Runs the host (test pattern, throwaway keys) and the probe through clamshell-netsim once per
# network profile, all on this Mac. Prints one PROBE_SUMMARY line per profile.
#   tools/scripts/remote-paths.sh [seconds] [profile ...]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SECS="${1:-20}"; shift || true
PROFILES=("${@:-lan lte hotel bad congested}")
HOST_BIN="$ROOT/mac-host/build/dd/Build/Products/Debug/ClamshellHost.app/Contents/MacOS/ClamshellHost"
BIN="$ROOT/tools/.build/release"
OUT="${TMPDIR:-/tmp}/clamshell-remote-paths"; mkdir -p "$OUT"
RELAY_PORT=51900

[[ -x "$HOST_BIN" ]] || { echo "build the host first (docs/SETUP.md)"; exit 1; }
[[ -x "$BIN/clamshell-netsim" && -x "$BIN/clamshell-probe" ]] || (cd "$ROOT/tools" && swift build -c release)

pkill -x ClamshellHost 2>/dev/null || true
CLAMSHELL_EPHEMERAL_KEYS=1 CLAMSHELL_TEST_PATTERN=1 CLAMSHELL_RATE_LOG=1 "$HOST_BIN" > "$OUT/host.log" 2>&1 &
HOST_PID=$!
trap 'kill $HOST_PID 2>/dev/null || true; kill ${NETSIM_PID:-0} 2>/dev/null || true' EXIT
for _ in $(seq 50); do grep -q CLAMSHELL_UDP_PORT "$OUT/host.log" && break; sleep 0.2; done
CODE=$(sed -n 's/^CLAMSHELL_DEV_CODE=//p' "$OUT/host.log" | head -1)
PORT=$(sed -n 's/^CLAMSHELL_UDP_PORT=//p' "$OUT/host.log" | head -1)
[[ -n "$CODE" && -n "$PORT" ]] || { echo "host did not start:"; cat "$OUT/host.log"; exit 1; }
echo "host on UDP $PORT"

for p in ${PROFILES[@]}; do
  "$BIN/clamshell-netsim" --to "127.0.0.1:$PORT" --listen $RELAY_PORT --profile "$p" > "$OUT/netsim-$p.log" 2>&1 &
  NETSIM_PID=$!
  sleep 0.5
  "$BIN/clamshell-probe" client --code "$CODE" --host 127.0.0.1 --port $RELAY_PORT --seconds "$SECS" > "$OUT/probe-$p.log" 2>&1 || true
  kill $NETSIM_PID 2>/dev/null || true; wait $NETSIM_PID 2>/dev/null || true
  echo "$p: $(grep PROBE_SUMMARY "$OUT/probe-$p.log" || echo 'no summary, see '"$OUT/probe-$p.log")"
  sleep 1
done
echo "logs: $OUT"
