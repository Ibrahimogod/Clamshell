# Setup from zero (through 1.0: pairing, internet paths, postures, sound and files, hardening, release builds)

This gets you from a fresh clone to the Mac's screen on the iPhone Duo over home Wi-Fi, with the HUD and
the bench tools. It assumes nothing is installed except macOS and Xcode. Nothing here uses a third-party
service: discovery is Bonjour on your LAN and pairing is a code you copy by hand. (M3 replaces the code
with QR pairing and adds the internet paths.)

**Tested with:** MacBook Pro M5 on macOS 27.2, Xcode 27.2 (Swift 6.4), iOS 26 SDK.

## 0. One-time prerequisites

1. **Xcode 27.2** from the App Store. Open it once and accept the licence, so the command-line tools work.
2. **Homebrew** (https://brew.sh), then:
   ```bash
   brew install xcodegen
   ```
   `xcodegen` generates the Xcode projects from `project.yml`. (`brew install ffmpeg` too only if you want the optional
   second-phone filming variant of harness B.)
3. **Your Apple Developer account** signed in to Xcode: Xcode › Settings › Accounts.
4. **On the Duo:** Settings › Privacy & Security › Developer Mode → On (the phone restarts). Connect it to the Mac with a cable the first time, and tap "Trust".

## 1. Your signing config

```bash
cp mac-host/Config/Local.xcconfig.example mac-host/Config/Local.xcconfig
```

Edit `mac-host/Config/Local.xcconfig`:
- `DEVELOPMENT_TEAM`: your 10-character Team ID, from developer.apple.com › Account › Membership details;
- `CLAMSHELL_BUNDLE_PREFIX`: a reverse-DNS prefix you own, e.g. `com.yourname.clamshell`. The apps become `<prefix>.host` and `<prefix>.client`.

Both apps read this one file. It's gitignored.

> **Why a team and not "Sign to Run Locally":** with an ad-hoc signature, every rebuild is a new identity to macOS. The Screen Recording grant stops applying and the Keychain asks for permission again on each launch (in M1 testing that prompt made the host hang with no window). With your team, the grant survives rebuilds.

## 2. Check the shared code

```bash
cd shared && swift test
```

Expect all suites to pass (wire, Noise, transport, rate control, stream pipelines with real VideoToolbox).
The stream tests take ~10 s because they really encode and decode.

## 3. The Mac host

```bash
cd mac-host && xcodegen generate && open ClamshellHost.xcodeproj
```

In Xcode, pick the **ClamshellHost** scheme and **My Mac**, then Run (⌘R). A menu-bar item appears. The app has
no Dock icon.

First run:
1. **Local Network:** click Allow if macOS asks.
2. **Screen Recording:** click **Allow Screen Recording…** in the menu. In System Settings › Privacy & Security › Screen & System Audio Recording, turn **ClamshellHost** on. Then quit the host (menu › **Quit Clamshell Host**) and run it again from Xcode. macOS only applies the grant to a fresh process.
3. **Pairing** happens from the phone (step 4.3). The menu lists paired phones; **Revoke** removes one and ends its session at once, **Disconnect all** ends every session, **Pause remote access** refuses all sessions and closes the internet listener until switched off (LAN pairing still works).

4. **Keyboard & mouse (M2):** click **Allow keyboard & mouse control…** in the menu. macOS shows its
   Accessibility prompt; open System Settings › Privacy & Security › Accessibility (macOS 27: **Device Control**) and turn **ClamshellHost**
   on. Until then the phone shows a banner and its keys and trackpad do nothing. Like Screen Recording, the
   grant belongs to this exact build: a rebuilt or moved app may need it again (remove the old entry with −).
5. **Clipboard (optional):** **Sync clipboard with the phone** in the menu sends Mac copies to the phone.
   On the phone, the clipboard button in the bar under the screen sends the phone's clipboard to the Mac
   (iOS asks before an app reads it, so it's never automatic in that direction).
   Items a password manager marks as concealed or transient never leave the Mac.
6. **Sound, files, staying reachable (M5), all in the menu:**
   - **Play this Mac's sound on the phone** (on): system audio goes to the phone while streaming. It uses
     the same Screen Recording grant as the picture. Mute it on the phone with **Sound** in the Layout menu.
   - **Accept files from the phone (to Downloads)** (off): turn it on to let the phone's share button in
     the bar drop files (up to 32 MB) into ~/Downloads. If macOS asks whether ClamshellHost may access the
     Downloads folder, click Allow.
   - **Keep this Mac awake while plugged in** (off): stops idle sleep on the power adapter only, so the phone
     can always reach it. The display still sleeps; a connecting phone wakes it.
   - **Open at login** (off): starts the host when you log in. It appears in System Settings › General ›
     Login Items, where you can also turn it off. It needs the app in a fixed place (e.g. /Applications).
7. **Someone at the Mac (M6):** with Accessibility granted (item 4), using the Mac's own keyboard or mouse
   pauses the phone's input until the Mac has been left alone for 3 s; the phone shows "Someone is using the
   Mac". Press **Esc three times quickly** on the Mac to end every session. macOS asks once whether
   ClamshellHost may show notifications: allow it to get a notice each time a phone connects.

The host advertises itself on the LAN as `_clamshell._udp` (Bonjour) on a random UDP port. It creates the
virtual display only while a phone is connected.

## 4. The iOS client on the Duo

```bash
cd ios-client && xcodegen generate && open Clamshell.xcodeproj
```
Keep only this project open in Xcode. Both projects use the local `shared` package and Xcode lets only one
open window load it ("Couldn't load shared because it is already opened…", then "Missing package product").
So the host runs from the command line (step 3) and Xcode is for the phone app.

Pick the **Clamshell** scheme and your Duo as the destination, then Run.

First run:
1. **Local Network:** tap Allow (needed for Bonjour).
2. **Probes (do this once, it's an M1 deliverable):** tap **Probes** › **Run decode probe**. It decodes three canned clips with the hardware decoder required: VideoToolbox 4:4:4, x265 4:4:4 and a 4:2:0 control. Send me the screen, or the Xcode console output from a run with the `--probe` launch argument (Product › Scheme › Edit Scheme › Run › Arguments). If 4:4:4 passes, the app tells the Mac it can take 4:4:4. Otherwise the stream uses 4:2:0 + refinement.
3. **Pairing (once, at home, phone on the Mac's Wi-Fi):** on the Mac, menu › **Pair new iPhone…**, confirm with
   your password or Touch ID. A window shows a QR code and a 16-character code; it stays open 120 s. On the
   phone, **Scan the Mac's pairing code** (or type the code). Both screens then show 6 digits: if they match,
   click **Pair** on the Mac. Three wrong attempts close the window. Nothing goes through a server; the Mac
   accepts pairing only from addresses on your own network. Up to 8 phones.
4. Tap your Mac under **Macs on this network**. Within about a second the top half shows the Mac's virtual display at 1:1.

On the stream screen the bar under the Mac's screen shows the path in use (lan / udp / tcp) and its round
trip, and has buttons for the HUD (fps, Mbit/s, chroma, encode/decode ms, drops, barcode latency), sending
the phone's clipboard, sending a file (when the Mac accepts files), the Layout menu (posture pin, lower
half, touch clicks, sound, key remaps), the keyboard, and disconnecting.

**Postures (M4).** Half open with the fold horizontal is the laptop layout (Mac above, keyboard and trackpad
below); turned sideways it's the book layout; fully open is one big screen where taps click; closed, the
cover screen shows a glance. The Mac's display changes shape to match about half a second after you settle.
A Bluetooth keyboard and mouse work while streaming; ⌥-Tab and ⌃-Space reach the Mac as ⌘-Tab and ⌘-Space
(iOS keeps those).

On the Mac, apps open on the main display by default. Drag a VS Code window onto the "Clamshell" display
(System Settings › Displays shows where it sits), or set it as the main display while testing.

## 4b. Away from home (LTE, another Wi-Fi, a work network)

Bonjour only works on the same network. From outside, the phone reaches your home's public address, and
races two paths: UDP (fast) and TLS + WebSocket on TCP 443 (gets through networks that only allow web
traffic). Whichever answers first is used; it moves between them by itself.
1. Fix the Mac's UDP port (otherwise it's random each launch):
   `defaults write <host bundle id> udpPort 51820`, then relaunch the host. The host prints
   `CLAMSHELL_UDP_PORT=51820` and `CLAMSHELL_TCP_PORT=443` on start.
2. On the router (Archer VR400: Advanced › NAT Forwarding › Virtual Servers), forward **UDP 51820** and
   **TCP 443** to the Mac's LAN IP. Give the Mac a DHCP reservation first. Keep UPnP off, and keep the
   router's **remote management off** (it would otherwise want 443 itself).
3. The Mac's public address: the menu shows **Public address: …**. The Mac asks the router (NAT-PMP, read
   only, opens no ports) every 10 minutes; if your router doesn't answer that, type the address (the
   router's WAN IP, or a DNS name you own) in the pairing window's **Away-from-home address** field. If it
   starts with 100.64–100.127 your ISP uses CGNAT and nothing can reach you from outside; that needs a relay
   on a server, which this setup deliberately doesn't use.
4. The phone learns the address when it pairs and again on every session at home, and fills **Away from
   home** itself. You can still type `ip:51820` there. **Check connection** (on the phone, under Network
   check) tries LAN, UDP and TCP 443 one by one and shows which answer.

While streaming, the Mac stays awake and won't start the screen saver or lock from idle. If it was already
locked, the phone shows "The Mac is locked" (unlocking through the stream comes with M2 input).

Rehearse a bad network on this Mac alone, no second machine:
```bash
tools/scripts/remote-paths.sh 20 lte hotel bad congested
```
or by hand: `clamshell-netsim --to 127.0.0.1:<host port> --listen 51900 --profile lte` and point the phone
(same Wi-Fi) at `<mac LAN ip>:51900` with **Away from home**. `CLAMSHELL_RATE_LOG=1` on the host prints
every rate decision.

## 4c. Everyday use: a release build (no App Store)

One command builds both apps in Release, signed with your own Apple account, installs the host in
`/Applications` and puts the app on the phone (the Duo first if several phones are connected;
`CLAMSHELL_DEVICE=<name or UDID>` picks another). The phone has to be unlocked.

```bash
tools/scripts/release.sh
```

- **The Mac host** runs from `/Applications/ClamshellHost.app`. A zip of it is in `dist/`. Its permissions
  carry over from the Xcode build because the signing certificate is the same. If the menu asks again, switch
  ClamshellHost on in System Settings › Privacy & Security. On macOS 27 keyboard and mouse control is under
  **Device Control** (earlier versions call it **Accessibility**), and Screen & System Audio Recording is
  under **Data Access**. Turn **Open at login** off and on once in the menu so the login item points at
  /Applications.
- **The log**: `~/Library/Logs/Clamshell/host.log` whenever the host starts from Finder, the Dock or at login.
- **The phone app** is signed with your Apple account's provisioning profile. With a free account that profile
  lasts **7 days**. The script prints when it expires, and after that the app won't open until you run the
  script again. Pairings and settings are kept. A paid Apple Developer Program account makes it a year. It also
  allows Developer ID signing and notarization, which you need only to give the Mac app to other people.
- **What you see**: by default the phone shows this Mac's own screen, scaled to fit, with the whole desktop
  and every app. The menu switch **Show this Mac's own screen** turns that off, and you get a separate screen
  sized for the phone. Folding the Duo doesn't rebuild the picture while it shows the Mac's screen.

### Typing in Arabic and English

Keys go to the Mac as key positions, so the Mac's own keyboard layout decides what they type.

1. On the Mac, add the layouts you want in System Settings › Keyboard › Text Input › Edit (e.g. ABC and Arabic).
2. On the phone's keyboard, **tap 🌐** (bottom left) to switch the Mac to its next layout. The key shows the
   current one (**🌐 EN**, **🌐 ع**). **Hold 🌐** with another key to use it as fn (F-keys, Home/End,
   forward delete).
3. The phone's keys show what the Mac's layout types: Arabic letters for Arabic, with the English letter small in
   the corner for ⌘ shortcuts (⌘C is still the C key). Shift shows the shifted characters (harakat etc.).
   Switching at the Mac (its input menu, ⌃Space, its own 🌐) updates the phone's keys too.

This needs a host and app from protocol 1.6 (version 1.0.0 or later). With an older Mac, 🌐 is a plain fn key.

## 5. Bench harnesses

Build the tools once:

```bash
cd tools && swift build -c release
```

| Harness | What | How |
|---|---|---|
| A (capture → present) | Automatic on every session. The Mac draws an 8×8 barcode (frame id + Mac clock) in the virtual display's top-left; the phone reads it from each decoded frame and maps it through clock sync. | HUD line 4. Toggle: host menu › "Latency barcode (harness A)" |
| B (glass → glass) | Ground truth: the Duo's own rear camera watches the Mac's flash square while its screen shows the stream | See below |
| C (input → photon) | Stub until M2. `clamshell-bench impair <hotel\|lte\|tcp-only>` prints the network-shaping commands for later fallback tests (it never runs them) | — |
| D (text sharpness) | Encodes a scroll then a still on this Mac, decodes it, and reports the PSNR of every frame after the screen goes still. Pass = ≥ 45 dB within 150 ms | `tools/.build/release/clamshell-bench text-refine [--bitrate 25]` |

**Harness B: the glass-to-glass camera test** (one device, no filming, ~1 minute):
1. On the Mac: host menu › turn on **Flash square (glass-to-glass test)**. While a phone is connected, a square flips
   black/white every 400–500 ms in the top-right corner of the MacBook's screen (260 pt) and of the streamed
   display (160 pt), in the same step.
2. On the Duo, before connecting: turn on **Latency test › Glass-to-glass camera test**. The first time, allow the
   camera (it's only used for this test; nothing is recorded or sent).
3. Stand the Duo 20–40 cm in front of the MacBook with its **rear camera facing the Mac's screen**, so the flashing
   square is in view. Lean it against something so it doesn't move. Then connect (tap your Mac).
4. The phone's camera runs at its fastest rate (240 fps where available), finds the flashing square by itself in
   2–3 s, and times every flip. Its own screen times the same flip in the stream. Both use the phone's clock, so
   no clock sync is involved. The HUD's last line reads
   `glass-to-glass (camera) p50 … · p95 … ms (n …) · cam … fps`. Wait for n ≥ 40 (about 20 s).
   Exit criterion: **p50 ≤ 50 ms**. With the app run from Xcode, the same line prints to the console every 2 s.
5. If the HUD says "looking for the flash square", the camera can't see it. Move the phone closer, or tilt it.

What it measures: how much later the Duo shows a change than the Mac's own panel does, i.e. (virtual display,
capture, encode, Wi-Fi, decode, present) minus the Mac panel's own draw → photon time. For the absolute draw →
presented time, use the HUD's barcode latency (harness A). To see every flip, run from a terminal:
`xcrun devicectl device process launch --console --device <udid> <prefix>.client --camera-test`
(each matched flip prints `# flip up|down lag … ms`). A cluster near 75–100 ms is Wi-Fi stalls, not the codec.
Biases, each small: the camera edge is ~half an exposure late (≤ 2 ms at 240 fps) plus rolling-shutter readout;
the phone side uses the display link's target time and not the panel's pixel response; the Mac panel and the
virtual display flip on their own vsyncs (≤ 8.3 ms apart).

*Optional variant:* film both screens with a second phone at 240 fps and run
`python3 tools/bench/harness_b.py clip.mov --fps 240` (needs ffmpeg; self-test `python3 tools/bench/test_harness_b.py`).

**Upload test** (sets the remote video budget for M3): this one needs two places. It measures your home line's
*upload*, so the bytes have to leave the house through the VDSL line and land on something you own outside it.
A test where both ends are this Mac never touches the line. The own-devices way is the Duo **on cellular** as the
receiver. That needs the port forwards from step 4b (TCP 443 + UDP 51820). The tools are ready: `tools/bench/upload_sink.py` (receiver) and
`clamshell-bench upload --to <host>:<port>` (sender).

## 6. Knobs and troubleshooting

| Setting | Where | Effect |
|---|---|---|
| `bitrateMbps` | `defaults write <prefix>.host bitrateMbps -int 50` | LAN video bitrate (default 50; 25 drops frames on full-screen scroll) |
| `udpPort` | `defaults write <prefix>.host udpPort -int 51820` | Fixed UDP port instead of a random one (M3 needs this for the router forward) |
| `CLAMSHELL_TEST_PATTERN=1` | host environment (Xcode scheme or shell) | Synthetic frames (1 s scroll, 1 s still) instead of screen capture. No Screen Recording needed |
| `tcpPort` | `defaults write <prefix>.host tcpPort -int 443` | Port of the TLS + WebSocket listener (0 is not allowed; pause remote access instead) |
| `publicHost` | pairing window field, or `defaults write <prefix>.host publicHost home.example.org` | Away-from-home address given to phones; overrides the router's answer |
| `CLAMSHELL_EPHEMERAL_KEYS=1` | host environment | In-memory identity and pairings, no Keychain. Use it for ad-hoc builds and scripted runs |
| `CLAMSHELL_FLASH=1` | host environment | Starts with the harness B square on |
| `CLAMSHELL_PAIR_ON_START=1` | host environment, Debug builds only | Opens a pairing window at launch without the password prompt and prints `CLAMSHELL_PAIR_INVITE=…` |
| `CLAMSHELL_PAIR_AUTOCONFIRM=1` | host environment, Debug builds only | Confirms the SAS without a click. For scripted runs only: it skips the check that stops a stolen QR code |
| `CLAMSHELL_PAIR_INVITE=CLAMPAIR1:…` | client environment (`SIMCTL_CHILD_` prefix for `simctl launch`) | Pairs with that invite at launch |
| `--host h:port`, `--auto-connect`, `--network-check` | client launch arguments | Connect to an address / to the first Mac found; run the network check after pairing |

The host prints the invite and one line per session to stdout. A scripted run on the Mac alone, with the
iOS Simulator as the phone:

```bash
open -n --env CLAMSHELL_EPHEMERAL_KEYS=1 --env CLAMSHELL_PAIR_ON_START=1 --env CLAMSHELL_PAIR_AUTOCONFIRM=1 --stdout $PWD/host.log --stderr $PWD/host.log mac-host/build/dd/Build/Products/Debug/ClamshellHost.app
```

```bash
SIMCTL_CHILD_CLAMSHELL_PAIR_INVITE=$(grep -o 'CLAMPAIR1:[^ ]*' host.log | tail -1) xcrun simctl launch booted <prefix>.client --auto-connect --host 127.0.0.1:51820
```

(`--host 127.0.0.1:9` forces the TCP 443 path, since nothing answers UDP on port 9.) Build the host into
`mac-host/build/dd` with `xcodebuild -project ClamshellHost.xcodeproj -scheme ClamshellHost -derivedDataPath build/dd build`.

- **"Could not connect"** on the phone: both devices on the same Wi-Fi (no guest network or client isolation)? Host still running? Paired with this Mac (Pairing section)? If you revoked the phone or reinstalled an app, pair again.
- **"This phone's key could not be read from the Keychain"**: the app was built without a team signature. Check `Local.xcconfig`.
- **Black screen, host menu says "Screen Recording permission is needed to stream."**: step 3.2, then relaunch the host.
- **Text soft while scrolling, sharp ~125 ms after you stop:** that's expected. It's the refinement pass (ADR-0008).
- **The Mac's windows jump when the phone connects or disconnects:** expected in M1. The virtual display comes and goes with the session (ADR-0007; M4 restores positions).
- **iOS Simulator:** it works for UI and plumbing (it uses software decode, ~30–50 fps). It has no hardware HEVC, so the Probes screen fails there by design.

## Mac-side probes (already run; re-run after macOS updates)

```bash
tools/.build/release/clamshell-probe encode
```

HEVC profiles, 4:4:4 recipe, encode latency (ADR-0006).

```bash
tools/.build/release/clamshell-probe crypto
```

Noise seal/open cost per frame.

```bash
tools/.build/release/clamshell-probe display
```

Virtual display and SCK at 120 Hz (ADR-0007). The capture part needs Screen Recording for your terminal app.
