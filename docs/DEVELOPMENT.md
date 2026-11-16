# Development

Working on the code. To just build and use the apps, [SETUP.md](SETUP.md) is enough. The design is in
[architecture.md](architecture.md), [protocol.md](protocol.md), [video.md](video.md), [ux.md](ux.md),
[security.md](security.md) and the [ADRs](adr/README.md).

House rules: Swift 6 with strict concurrency, no force unwraps in networking or crypto code, every wire
message versioned, tests with every change, and a [CHANGELOG](../CHANGELOG.md) entry.

## Projects

| | Build | Notes |
|---|---|---|
| `shared/` | `cd shared && swift test` | The `ClamshellKit` package: wire, Noise, transports, video pipelines, rate control, input model. The stream tests take ~10 s because they really encode and decode with VideoToolbox |
| `mac-host/` | `cd mac-host && xcodegen generate` | `ClamshellHost.xcodeproj`, scheme **ClamshellHost**, not sandboxed |
| `ios-client/` | `cd ios-client && xcodegen generate` | `Clamshell.xcodeproj`, scheme **Clamshell** |
| `tools/` | `cd tools && swift build -c release` | `clamshell-probe`, `clamshell-bench`, `clamshell-netsim` |

Both apps read the signing config from `mac-host/Config/Local.xcconfig` ([SETUP.md §2](SETUP.md#2-your-signing-config-once)).
The generated `.xcodeproj` folders aren't in git; run `xcodegen generate` again after changing a
`project.yml` or adding files.

**Open one project at a time in Xcode.** Both use the local `shared` package, and Xcode lets only one open
window load it ("Couldn't load shared because it is already opened…", then "Missing package product"). Run
the host from the command line and use Xcode for the phone app, or the other way round:

```bash
cd mac-host && xcodebuild -project ClamshellHost.xcodeproj -scheme ClamshellHost -derivedDataPath build/dd build
```

```bash
open mac-host/build/dd/Build/Products/Debug/ClamshellHost.app
```

**Releases.** `tools/scripts/release.sh` builds both apps in Release (see [SETUP.md §3](SETUP.md#3-build-and-install)).
The version is `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in both `project.yml` files; keep them equal.
The apps send it to each other in `Hello` (`AppVersion` in `ClamshellWire`).

**Icons.** Both app icons and `docs/images/icon.png` are drawn by a script, so change the script and rerun it:

```bash
swift tools/scripts/make-icons.swift
```

## Debug switches

| Setting | Where | Effect |
|---|---|---|
| `bitrateMbps` | `defaults write <prefix>.host bitrateMbps -int 50` | LAN video bitrate (default 50; 25 drops frames on full-screen scroll) |
| `udpPort` | `defaults write <prefix>.host udpPort -int 51820` | Fixed UDP port instead of a random one |
| `tcpPort` | `defaults write <prefix>.host tcpPort -int 443` | Port of the TLS + WebSocket listener (0 isn't allowed; pause remote access instead) |
| `publicHost` | pairing window field, or `defaults write <prefix>.host publicHost home.example.org` | Away-from-home address given to phones; overrides the router's answer |
| `CLAMSHELL_TEST_PATTERN=1` | host environment | Synthetic frames (1 s scroll, 1 s still) instead of screen capture; no Screen Recording needed |
| `CLAMSHELL_EPHEMERAL_KEYS=1` | host environment | In-memory identity and pairings, no Keychain. For ad-hoc builds and scripted runs |
| `CLAMSHELL_FLASH=1` | host environment | Starts with the glass-to-glass flash square on |
| `CLAMSHELL_PAIR_ON_START=1` | host environment, Debug builds only | Opens a pairing window at launch without the password prompt and prints `CLAMSHELL_PAIR_INVITE=…` |
| `CLAMSHELL_PAIR_AUTOCONFIRM=1` | host environment, Debug builds only | Confirms the 6 digits without a click. Scripted runs only: it skips the check that stops a stolen QR code |
| `CLAMSHELL_PAIR_INVITE=CLAMPAIR1:…` | client environment (`SIMCTL_CHILD_` prefix with `simctl launch`) | Pairs with that invite at launch |
| `--host h:port`, `--auto-connect`, `--network-check` | client launch arguments | Connect to an address / to the first Mac found; run the network check after pairing |
| `--probe`, `--camera-test` | client launch arguments | Run the decode probe / the glass-to-glass camera test |
| `stickyModifiers` | client user default (`-stickyModifiers YES` launch argument) | ⇧⌃⌥⌘ latch on tap instead of being held |

## A scripted run on the Mac alone

The iOS Simulator can stand in for the phone (software decode, ~30–50 fps, no hardware HEVC, so the decode
probe fails there by design). Build the Debug host into `mac-host/build/dd` as above, then:

```bash
open -n --env CLAMSHELL_EPHEMERAL_KEYS=1 --env CLAMSHELL_PAIR_ON_START=1 --env CLAMSHELL_PAIR_AUTOCONFIRM=1 --stdout $PWD/host.log --stderr $PWD/host.log mac-host/build/dd/Build/Products/Debug/ClamshellHost.app
```

```bash
SIMCTL_CHILD_CLAMSHELL_PAIR_INVITE=$(grep -o 'CLAMPAIR1:[^ ]*' host.log | tail -1) xcrun simctl launch booted <prefix>.client --auto-connect --host 127.0.0.1:51820
```

`--host 127.0.0.1:9` forces the TCP 443 path, since nothing answers UDP on port 9.

`tools/scripts/remote-paths.sh [seconds] [profile …]` runs the host (test pattern, throwaway keys) and the
probe through `clamshell-netsim` once per network profile, all on this Mac, and prints one `PROBE_SUMMARY`
line per profile.

## Logs

- **Host:** `~/Library/Logs/Clamshell/host.log` when it starts from Finder, the Dock or at login (stdout when
  started with `open --stdout`). While streaming it adds `stats:`, `path:` and `input:` lines every 10 s.
- **Phone:** run the app with its console attached:
  ```bash
  xcrun devicectl device process launch --console --device <udid> <prefix>.client
  ```
  `xcrun devicectl list devices` shows the UDID.

## Bench harnesses

| Harness | What | How |
|---|---|---|
| A (capture → present) | Automatic on every session. The Mac draws an 8×8 barcode (frame id + Mac clock) in the top-left of the streamed screen; the phone reads it from each decoded frame and maps it through clock sync | HUD latency line. Toggle: host menu › **Latency barcode (harness A)** |
| B (glass → glass) | The phone's rear camera watches the Mac's flash square while its own screen shows the stream | Below |
| C (network) | `clamshell-bench impair <hotel\|lte\|tcp-only>` prints network-shaping commands (it never runs them) | — |
| D (text sharpness) | Encodes a scroll then a still on this Mac, decodes it, and reports the PSNR of every frame after the screen goes still. Pass = ≥ 45 dB within 150 ms | `tools/.build/release/clamshell-bench text-refine [--bitrate 25]` |

**Harness B, the glass-to-glass camera test** (one phone, ~1 minute):
1. On the Mac: host menu › **Flash square (glass-to-glass test)**. While a phone is connected, a square flips
   black/white every 400–500 ms in the top-right of the MacBook's screen and of the streamed screen.
2. On the phone, before connecting: **Latency test › Glass-to-glass camera test** (allow the camera; nothing is
   recorded or sent).
3. Stand the phone 20–40 cm from the MacBook with its rear camera facing the screen, then connect.
4. The camera (240 fps where available) finds the square in 2–3 s and times every flip against the same flip in
   the stream, both on the phone's clock. The HUD's last line reads `glass-to-glass (camera) p50 … · p95 … ms`.
   Wait for n ≥ 40. Target: p50 ≤ 50 ms. `--camera-test` with the console attached prints every flip.

It measures how much later the phone shows a change than the Mac's own panel does. For absolute draw →
present time, use harness A. Optional variant: film both screens with a second phone at 240 fps and run
`python3 tools/bench/harness_b.py clip.mov --fps 240` (needs ffmpeg).

**Upload test:** `tools/bench/upload_sink.py` (receiver, e.g. on the phone's network) and
`clamshell-bench upload --to <host>:<port>` (sender) measure the home line's upload through the port forwards.

## Mac-side probes

Re-run after macOS updates:

| Command | Checks |
|---|---|
| `tools/.build/release/clamshell-probe encode` | HEVC profiles, the 4:4:4 recipe, encode latency (ADR-0006) |
| `tools/.build/release/clamshell-probe crypto` | Noise seal/open cost per frame |
| `tools/.build/release/clamshell-probe display` | Virtual display and capture at 120 Hz (ADR-0007); needs Screen Recording for your terminal |

On the phone, **Probes › Run decode probe** decodes canned 4:4:4 and 4:2:0 clips with the hardware decoder; if
4:4:4 passes, the app tells the Mac it can take 4:4:4.
