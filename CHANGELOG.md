# Changelog

All notable changes per milestone. Dates are 2026.

## Unreleased: The Mac notices a new home address, and phones follow it

- **The Mac reads the home's public address from the router over UPnP**, once a minute, the same way it
  opens the ports: no router password, no signing in to the router page. (An earlier build of this release
  signed in to the TP-Link VR400's web page with the admin password; that's gone, and the saved password is
  deleted from the Keychain at the next launch.)
- **Fix: the phone couldn't connect away from home when the network was slow.** It sends a new handshake
  every 500 ms while connecting and only accepted an answer to the newest one, so when an answer took longer
  than half a second (mobile data, a router that just restarted) every answer was thrown away and the
  connection timed out. It now accepts an answer to any of its recent handshakes. New test with a 1.2 s path.
- **UDP 443 instead of 51820.** 51820 is WireGuard's port and the owner's mobile network dropped the Mac's
  answers on it; 443 (HTTP/3's) gets through. SETUP §6 now fixes the Mac's port at 443, and the phone
  defaults to 443 and also tries it when its saved port is another, so a Mac moved to 443 isn't lost.
- **Fix: the TCP 443 path (TLS + WebSocket) never worked on the phone.** App Transport Security refused the
  Mac's self-signed certificate even though the app accepts it (`-1200`), so a network that blocks UDP had
  no way through. duckdns.org and dedyn.io names are now exempt from ATS (nothing else is); a typed IP
  address or another domain still gets UDP only. The phone logs why that path fails.
- `--network-check` at launch runs **Check connection** on a paired phone (for checks over `devicectl`).
- **The Mac opens its own port forwards (UPnP).** No more Virtual Servers by hand: the Mac asks the router
  for UDP 443 and TCP 443 with a one-hour lease, renews every 30 minutes, and moves them at once when its
  own address on the home network changes (a new private Wi-Fi address, say). Paused remote access closes
  them. Needs UPnP on in the router; switch it off in **Home address…** to keep forwarding by hand. This
  reverses "keep UPnP off" (ADR-0005, amendment 2): any device at home can then open ports.
- **Fix: a router restart left the ports closed for up to 30 minutes.** The router wipes its forwards when it
  restarts, including ones the Mac made while it was still coming online, and the Mac only renewed every 30
  minutes. It now checks once a minute that its forwards are still there and opens them again if not.
- **A notification when the address changes**, also for a change while the host wasn't running.
- **A DuckDNS name for the phone.** With a free name from duckdns.org and its token saved in the same
  window, the Mac points the name at every new address (60 s TTL) and gives phones the name instead of the
  address. After a change the phone finds the Mac again on mobile data with nothing to type. Phones get the
  name at their next session. A typed address gives way to the name (the phone used to keep a typed
  number forever, so it kept dialing the old address); a typed name stays. The port can be left out of a typed
  address (`myhome.duckdns.org` dials UDP 443, or the Mac's own port). A domain of your own hosted at deSEC works too
  (deSEC's free dedyn.io names are closed to new accounts).
- The DuckDNS token is in the Keychain (`dns-token`), never in files or logs.
- New shared library `ClamshellHome`: the UPnP client (SSDP search, IGD description, SOAP: port mappings and
  the public address) and the DuckDNS/deSEC client, with 8 tests.
- Telling home sessions from away ones compares against the address even when phones dial the name.
- Docs: ADR-0005 accepted and amended three times (DuckDNS flagged as a third party you chose, UPnP port
  forwards by your decision, the address read over UPnP instead of the router page), SETUP §6,
  USAGE, security.md §7.

## 1.2.0: Privacy screen, unlock from the phone, big files and folders (2026-11-20)

Protocol 1.9, additive: 1.0–1.1 phones and Macs still work together, without the new features. The ideas for
these three come from looking at RustDesk (privacy mode, block user input, resumable file transfer); none of
its code is used.

- **Privacy screen on the Mac.** While a phone uses the Mac from away (the default; also **Always** or
  **Never** in the host menu), every physical display shows a black "In use remotely — Clamshell" screen with
  the phone's name and start time. The phone still sees the real screen: the panels are left out of the
  capture, and they only go up once that worked. When the phone drops, the cover stays 20 s for a reconnect;
  a local key or click lifts it sooner. If the host quits, it goes with it.
- **Turn off the Mac's keyboard and trackpad** while the screen is hidden (off by default, host menu or the
  phone's new eye button). Esc pressed three times at the Mac still ends the session, and the power key is
  never blocked.
- **Unlock the Mac from the phone.** When the Mac is locked, the banner has an **Unlock…** button: type the
  password on the phone and it is typed on the Mac's login screen with the Mac's keyboard layout, then
  Return. Nothing is stored or logged.
- **Files and folders of any size, both ways.** Pick several files or whole folders on the phone or in the
  host's **Send Files to the iPhone…**. Each file is checked with SHA-256 and a folder keeps its structure
  ("Album 2" if "Album" is already there). A dropped connection or an app restart resumes where it stopped,
  from a partial copy kept for 7 days. Progress and **Cancel** in the host menu and in the phone's bar.
  Older peers still get the 32 MB single-file transfer.
- New shared library `ClamshellFiles` (send queue, receiver, listing), with tests for folders, reordered and
  dropped segments, resume after a restart, damaged files, refusals and cancel. `PasswordTyping` in
  `ClamshellInput`. Golden fixtures for the eight new or changed messages.
- Docs: protocol.md 1.9, ADR-0015 marked accepted with what was built, security.md T9 implemented,
  USAGE.md "Privacy screen" and "Unlocking the Mac from the phone".
- Not in this release: choosing which of several Mac displays to stream, and an IPv6 direct path.
- **Brushing the Mac's trackpad no longer pauses the phone.** The Mac pauses the phone's input while someone
  uses the Mac itself; a pointer move now counts only once it travels about 40 points within a second. Keys,
  clicks and scrolls at the Mac still pause it at once, and Esc ×3 still ends the session. Before, a hand
  resting near the trackpad while holding the phone froze the phone's pointer for 3 s at a time.
- **The pointer keeps up on mobile data.** Mobile networks deliver the phone's moves in clumps, and the Mac
  started each move from where macOS said the cursor was, which hadn't caught up with the moves just
  before it. Most of a clump's distance was lost and the phone's pointer snapped back by up to a third of
  the screen. While the phone is moving the pointer, the Mac now builds on the position it last set.
- When the phone's moves arrive in bursts, macOS can merge them into
  one event that has lost Clamshell's tag, and the Mac took that for someone at its trackpad: it paused the
  phone's input and the pointer snapped back afterwards. A move that ends where Clamshell just put the
  pointer now counts as the phone's. The Mac also reports the position it just set instead of reading the
  cursor back before the window server has caught up, and the phone's console logs how often and how far
  the pointer had to be corrected (`# pointer: N corrections`).
- The phone app writes its console line by line, so `xcrun devicectl device process launch --console` shows
  its notes (pointer, keyboard, Mac state) live instead of only when the app quits.
- It also keeps a copy in `Library/Application Support/console.log` (the run before: `console.1.log`), so a
  test on mobile data, out of reach of `--console`, can be copied off afterwards with
  `xcrun devicectl device copy from`.
- `tools/scripts/release.sh` installs on a phone named with `CLAMSHELL_DEVICE` even when devicectl lists it
  as disconnected. devicectl shows no capabilities for such a phone, so the old check skipped it.
- It also skips simulators: Xcode 27's devicectl lists them with the real phones, so a simulated iPhone Duo
  was picked over the connected phone and the install failed.
- The script now prints the earliest expiry of the app's and the widget's provisioning profiles, since the
  earlier one decides when the app stops opening.

## 1.1.0: Microphone, files to the phone, one window, battery saver, several Macs (2026-11-18)

Protocol 1.8, additive: 1.0 phones and Macs still work together, without the new features.

- **The phone's microphone on the Mac.** A mic button in the phone's bar sends its microphone to the Mac,
  with iOS voice processing so the Mac's sound doesn't echo back. The Mac plays it into **Clamshell
  Microphone**, a new loopback audio driver in the host app. You install the driver once with
  `tools/scripts/install-microphone.sh` (it asks for your password). `tools/scripts/test-microphone-driver.sh`
  checks the built driver in a test process without installing it (19 checks: properties, clock, loopback).
- **Files from the Mac to the phone.** Use **Send a File to the iPhone…** in the host menu, or Finder ›
  Services › **Send to iPhone with Clamshell**. Files land in the Files app under Clamshell › From Mac (up to
  32 MB each), with a share button in the bar and a list under **This phone › Files from the Mac**.
- **One window.** The window button lists the Mac's windows. Pick one and only that window is streamed, so it
  fills the phone. The Mac can resize it to show at 1:1. Input stays inside the window, it follows the window
  when it moves, and it goes back to the whole screen when the window closes.
- **Battery & heat saver** (This phone). Automatic: 60 fps on battery or when warm, 30 in Low Power Mode or
  when hot, full rate on the charger. Also Off and Always. The Mac encodes at the lower rate too.
- **Several Macs.** Pair more than one (**Pair another Mac…**), pick one from the list, and forget one with a
  swipe. Away from home the phone uses the chosen Mac's address.
- **Siri, Shortcuts and a widget.** Say "Connect to my Mac with Clamshell". There's a **Connect to My Mac**
  Shortcuts action (with an optional Mac name), a Home and Lock Screen widget, and a Control Center control.
  All of them open `clamshell://connect`, which tries the Wi-Fi for 2 s and then the away address. The widget
  is a third bundle ID (`<prefix>.client.widget`).
- **A warning before the phone app runs out.** A free Apple Account's build stops opening after 7 days. The
  phone now shows the date, warns from 3 days before and sends a reminder the day before. The Mac's menu shows
  it per phone too (from the new Hello field).
- Tests: golden fixtures for the four new messages and the new Hello and HostState fields, plus round trips and
  unit tests for the expiry dates and warnings, the saver's caps, the frame-rate rule and the window maths.
- Fixed after the first try on the Duo:
  - **The pointer vanished, files and the window list never arrived after the stream was rebuilt.** Picking
    a window, a resize, a posture change or a new frame-rate cap rebuilds the stream, and the Mac also reset
    its bulk sender, so transfer ids started again at 1. The phone remembers ids it has finished and
    acknowledged the new transfers as repeats without using them, so cursor shapes, window lists and files
    were lost. The Mac now keeps its bulk state for the whole connection. This also explains some earlier
    pointer losses after a posture change.
  - **Clicks in a streamed window hit other windows.** The window is captured on its own, so the phone shows
    it even when other windows cover it on the Mac. The Mac now brings it to the front when you pick it, and
    again before a click if something covers it.
  - The window picker's "Asking the Mac…" now gives up after 4 s with a Refresh hint.
  - Siri and Shortcuts only opened the app. They now hand the connect request to the app directly, including
    on a cold launch.

## 1.0.4: More frames when mirroring the Mac (2026-11-17)

- **Mirroring ran at about 65–75 fps, unevenly.** At 2670×1734 4:4:4 each frame was first converted to 4:4:4
  YCbCr (3–5 ms) and only then encoded (11.5 ms), one after the other, so the encoder sat idle during every
  conversion. The Mac now converts the newest capture on its own queue while the previous frame encodes. On
  the M5 a screen changing at 120 Hz now gives 79–89 fps instead of 69–71, the encoder's own limit at this
  size, with no added delay (`MirrorFrameRateTests`). Encoding two frames at once was measured too and
  rejected: 101 fps but 19 ms per frame instead of 11.5.
- The phone's stats overlay said "busy" next to the drop counts. Those captures aren't lost: a newer picture
  replaced them before the encoder was free. It now reads "skipped N (newer picture sent)".
- Tests: the path tests' inboxes could hand a new connection the inbox of a freed one (a reused object
  identity), which made them fail now and then.

## 1.0.3: Connecting by the home address at home (2026-11-17)

- **Connecting by address (the home IP) at home stayed on the router's loopback.** The phone adds the Mac's
  own Wi-Fi path to the race only if it has already seen the Mac on the Wi-Fi when you tap Connect. If not,
  the whole session went out to the router's public address and back, with more delay and the router in the
  way. Now the Wi-Fi path joins as soon as the phone sees the Mac, and the session moves onto it within about
  2 s, on the same connection (`# path: the Mac is on this Wi-Fi now` in the phone's console). A better
  path that comes up is probed straight away rather than at the next 2 s probe.
- **The Mac kept switching between the two addresses.** While the phone's paths race or probe, the Mac hears
  it on the Wi-Fi and through the router at once. It used to reply to whichever packet came last, so the video
  went back and forth between the two paths, arriving out of order and triggering keyframe requests. Last
  night's log shows that pattern: five stream starts in seconds, alternating `fe80…` and the public address.
  The Mac now stays on the local-network address while it hears the phone there, and moves only after 0.5 s
  of silence on it (Wi-Fi to mobile data still moves at once on the phone and within 0.5 s on the Mac).
  Tested with a path that alternates packets between the LAN and the 443 path; the test fails without the
  change.

## 1.0.2: The pointer after reconnects, no freezes after keyframes (2026-11-17)

- **The pointer vanished after a reconnect.** When the phone dropped off the Wi-Fi and connected again before
  the Mac had timed out its old session, the Mac took the new handshake for a rekey of the old one. It kept the
  old input state, so the new connection's input (numbered from 0 again) was thrown away as already seen and
  the pointer's shape was never sent: no pointer and no clicks until the old session expired, minutes later.
  The phone now sends a fresh random connection id in its Hello (protocol 1.7, Hello tag 9); a different id
  is a new connection and the Mac starts afresh. A real rekey keeps the id. Tested with two connections from
  one phone, the first never closed.
- **Frame drops after keyframes.** With low-latency rate control, VideoToolbox pays for a keyframe by dropping
  the frames after it when the target is low (the LAN target sits at 2–5 Mbit/s on a quiet desktop). At
  4 Mbit/s and 2670×1734 4:4:4 that was 19–33 frames, a 0.3–0.5 s freeze each time the phone asked for a
  keyframe; away from home at 3 Mbit/s, 11–23. The host now raises the encoder's average bitrate for the
  keyframe only (4× the target, at least 7.5 bits per pixel per second, capped at the session's ceiling) and
  restores it on the next frame. A real-encoder test shows 0 drops at both sizes, against 76 without it.

## 1.0.1: Smoother away from home, the picture is a trackpad (2026-11-16)

- **Away from home** (the session isn't on the local network) the host streams a lighter profile: at most
  1600 px wide, at most 60 Hz, HEVC 4:2:0, a 3 Mbit/s start and a single QP 24 refinement at 400 ms instead
  of the near-lossless QP 18/12 pair. Big 4:4:4 frames and lossless refinements filled a slow home upload and
  caused the delay and dropped frames. On the LAN nothing changed.
- **Connect at home** (the home address, while on the home Wi-Fi) used only the router's public address,
  which the router loops back. On this router that path carried pings but no video at all (the phone kept
  asking for keyframes, about 4 a second). The phone now also races the Mac it sees on the Wi-Fi and uses it,
  and the host counts a session from its own public address as home (full quality).
- The host log's `streaming to` line names the transport and source (`udp 1.2.3.4`, `wss …`), and a `path:`
  line every 10 s gives what the phone reported: KB received, fragment loss, FEC repairs, frames shown/lost,
  queuing delay, round trip and why it asked for keyframes.
- **Mobile data: the bitrate no longer sticks at the floor.** Cellular delay swings by 60–220 ms with no
  queue at all, and the rate controller took that for congestion even while the Mac sent 0.4 Mbit/s, so the
  target sat at 1.5 Mbit/s and every screen change came through blurry and late. It now learns the path's
  jitter while the sender is idle and counts only delay above it, and only while the sender uses at least half
  its target. Loss still backs off as before.
- **The pointer away from home.** The away picture (1600 px) is smaller than the Mac's screen, but the host
  applied the phone's moves in the screen's points while the phone predicted them in the picture's. The
  phone's pointer ran about 1.7× ahead, then snapped back with every report from the Mac, and was drawn 1.7×
  too big. The host now scales the phone's moves up to the screen and sends the pointer's shape at the
  picture's size, so both sides agree (shared `PointerSpace`, tested). The same applied at home in postures
  whose picture is smaller than the Mac's screen. The host log says `pointer: picture is smaller than the
  display, moves ×1.67` when it applies.
- More in the host log: an `input:` line every 10 s (messages from the phone, actions posted, refused for
  lack of Accessibility, dropped because someone was using the Mac) and, when the Mac's own keyboard or mouse
  pauses the phone, a `local input:` line naming the event and its process (pid 0 is real hardware). The
  guard also ignores events from the host's own process even without the Clamshell tag. The phone's console
  says why the pointer is or isn't drawn (`# pointer: …`) and prints each decode failure with its status.
- When a session's path moves between the LAN and the internet, the host restarts the stream with the matching
  profile.
- The host log gets a `stats:` line every 10 s (fps, Mbit/s and target, encode ms, keyframes, refinements,
  drops), so a laggy session can be read afterwards.
- **Touch on the picture is a trackpad in every posture** (laptop, book, flat, cover): drag moves the pointer
  relatively, tap clicks, two fingers scroll or right-click. "Touch clicks on the picture" in the Layout menu
  brings back direct touch, and it is now off by default (new setting key, so an old "on" doesn't carry over).
  The trackpad under the keyboard (laptop, book) stays as it was.
- **Pinch on the picture zooms the phone's view** (up to 5×) so small text is readable; the Mac doesn't change.
  The point under your fingers stays put, moving them while pinching pans, and while zoomed the view follows
  the Mac's pointer when it nears an edge. The pointer moves proportionally less while zoomed, so it stays as
  precise on screen. Pinch back out to see the whole screen. On the trackpad strip a pinch still sends
  ⌘= / ⌘− to the Mac app.
- **Bigger keys, and the deck is a setting** (Layout › Keyboard & trackpad…, also on the connect screen):
  key size (row height 36–64 pt, default 48 pt; 1.0.1's keyboard was capped at 260 pt, about 42 pt rows) with
  larger labels, show or hide the keyboard and the trackpad strip, the strip's size, and in laptop posture the
  strip below or beside the keyboard. Saved on the phone (`DeckSettings`); the old "lower half" choice carries
  over. The Layout menu keeps a quick Trackpad strip switch.
- **Book posture splits the deck at the fold.** The Mac's picture stays as it is, across both pages, and the
  Mac's display no longer changes shape when you turn the Duo sideways (book uses the laptop display mode).
  Below it the keyboard splits like a split MacBook keyboard (after 6, T, G, B and F6; each half has a space
  bar, the arrows are on the right). Each half keeps MacBook-shaped keys at its page's outer edge, and the
  trackpad strip, when shown, sits between the halves as one pad per page beside the fold, so it takes no
  height from the picture (a first try stretched the keys across each page and put the strip underneath,
  which left the picture small). fn, caps lock and sticky modifiers work across both halves. Nothing sits on
  the fold, a touch that starts there is ignored, and a finger on each page still makes one two-finger gesture.
- **Ready for anyone to build.** App icons for both apps (drawn by `tools/scripts/make-icons.swift`, also
  `docs/images/icon.png`). `tools/scripts/configure.sh` finds your Apple team from its Apple Development
  certificate and writes `Local.xcconfig`, and `release.sh` checks Xcode, xcodegen and the signing config
  first and says what's missing. New README, a from-zero [SETUP](docs/SETUP.md) (including the Untrusted
  Developer step, updating and uninstalling), [USAGE](docs/USAGE.md) and [DEVELOPMENT](docs/DEVELOPMENT.md).
  Version 1.0.1 (3), and the apps now send their real version in `Hello` instead of a fixed "0.1.0". Two
  Swift concurrency warnings are gone (the connect notification and the pairing digits callback). The
  project is now under the [MIT License](LICENSE).

## 1.0.0: Everyday use, Arabic/English typing (2026-11-16)

### Added
- **Arabic and English typing (protocol 1.6).** 🌐 on the phone's keyboard (where fn was), tapped alone, selects
  the Mac's next keyboard input source (`KeyboardLayouts.selectNext`, Text Input Sources). Held with another
  key, it is fn. The Mac sends its layout (`KeyboardLayout` 0x0024, via bulk) at session start and on every
  change, from anywhere. The phone labels its keys from it: Arabic letters with the English letter in the
  corner, shifted characters with Shift, and a dotted circle under combining marks. Keys still go out as positions.
- **Mirror mode** (default on): the phone shows the Mac's own main display, scaled to fit the phone's largest
  mode. Folds don't rebuild it. The menu switch "Show this Mac's own screen" switches back to a separate
  virtual display. Cursor reports and pointer input follow the mirrored display.
- **Release builds**: `tools/scripts/release.sh` regenerates the projects and builds both apps in Release with
  your own signing. It installs the host in /Applications and zips it into `dist/`, installs the app on the
  Duo (`CLAMSHELL_DEVICE` picks another phone), and prints when the phone's provisioning profile expires.
- Host log file `~/Library/Logs/Clamshell/host.log` when not started from a terminal. It logs permission state
  at launch, permission changes, local-user pauses, layout changes and layout switches.
- Version 1.0.0 (build 2) for both apps.

### Verified
- Shared suite passes, with a new golden fixture `keyboard_layout.hex`, a fuzz entry for `KeyboardLayout` and a
  receiver test: 🌐 gives exactly one `nextInputSource`, holds nothing, and other vendor pages are ignored.
- Release builds of both apps. The host in /Applications reports `accessibility trusted: true · post events:
  true`, screen recording allowed. The app is installed on the Duo.
- On the Duo (owner test): 🌐 switches the Mac between ABC and Arabic, and Arabic typing and labels work.
- Away from home (owner test, 2026-11-16): the Duo on another network connects through the router's port forward
  (UDP 51820 to the Mac). The session ran over UDP from the phone's public address, and a TCP 443 connection from the
  same address also reached the host. Pairing stays LAN-only: away from home, use Connect, not the QR code.
- The label reader against this Mac's Arabic layout: a→ش, s→س, q→ض (Shift: fatha), 1→١, /→/ (Shift: ؟).

### Not verified
- Whether `TISSelectInputSource` from the background host is picked up by every app at once. It is for plain
  layouts like ABC/Arabic. Input methods (CJK) sometimes need a focus change.
- A hardware keyboard on the phone has no 🌐 (GameController doesn't report it). Use the deck's 🌐, or the
  Mac's own shortcut, e.g. ⌃⌥Space.

### Notes
- macOS 27 shows Accessibility as **Privacy & Security › Device Control**. SETUP.md says so.
- Signed with an Apple Development certificate (free account): the phone app needs re-signing every 7 days.
  Developer ID and notarization are only needed to give the Mac app to others.

## M6: Hardening, fuzzing, App Store prep (2026-11-16)

**Verified** (this Mac + iOS Simulator):
- shared suite: wire fuzzing (every golden fixture mutated through the envelope, each message body and the bulk
  receiver) and session fuzzing (initiations with MAC1 recomputed, transport and pairing packets), no crashes or wrong
  acceptances; handshake rate limiter (per-source burst and refill, global cap, table pruning); `HostState.localUser`
  round trip and fixture;
- the probe now pairs for real (`--invite`) instead of the debug PSK, then streams;
- iOS build includes the privacy manifest and declares its encryption;
- 10 minute soak on loopback (probe, test pattern + test tone, 120 Hz): 2351 frames decoded, **0 lost, 0 decoder
  errors**, 3 keyframe requests, 3.3 Mbit/s, ping p50 0.94 ms; capture → decoded p50 25.6 ms, p95 425 ms. The p95 is
  most likely the refinement frames (9 % of frames here), which keep the capture time of the still frame they sharpen
  while the pattern holds still for 1 s; not proven. Host memory flat during the session (about 0.9–1.0 GB, nearly
  all the test pattern's pre-rendered full-size frames, so a test-mode cost only);
- the soak found a real bug (fixed below): after the probe exited, the host kept streaming for up to 180 s. Now it
  stops 10 s after the phone goes quiet, and memory went back from 1.1 GB to 88 MB.

**Not verified:** the local-user guard and Esc×3 by hand (needs Accessibility for the host), the session-start
notification prompt, an 8 hour soak with network flaps, a SETUP run on a fresh Mac.

**Fixed**
- A phone that vanishes (app killed, out of coverage, a probe that exits) used to keep the Mac streaming, with the
  virtual display up, until the session keys expired (180 s). The host now drops a session after 10 s with nothing
  from the phone, which pings at least once a second while connected (`HostSessionServer.idleTimeout`, test
  `silentPhoneIsDropped`).

**Added**
- `HandshakeLimiter` in front of every handshake (T8); MAC1 still drops scanners first.
- `LocalUserGuard` (T9): local use pauses phone input until the Mac is idle 3 s, the phone shows a banner, Esc×3
  ends all sessions, a notification on each session start.
- `developmentPSK` only in DEBUG builds.
- `PrivacyInfo.xcprivacy`, `ITSAppUsesNonExemptEncryption = true`, docs/app-store.md; the stale `CLAMSHELL_DEV_CODE`
  scheme variable removed.
- docs/security.md §10: implementation status per threat.

**Deferred:** Secure Enclave key wrap (T1), the sandboxed Edge XPC helper (T3), MAC2 cookie mode and the WebSocket
2 s close (T8), curtain and dimmed panel (T9), the relay (no VPS by choice), the HTTPS stream fallback (P4), the
small-damage overlay experiment, packet-size padding.

## M5: Extras: sound, files, clipboard filter, wake, auto-start (2026-11-16)

**Verified** (this Mac + iOS Simulator):
- shared suite: Opus round trip (1 s of tone in SCK-sized chunks → 20 ms packets, consecutive seqs, 20 ms
  timestamps, decodes back to sound), the jitter rule (starts at 40 ms queued, drops over 120 ms, duplicates
  and stale packets dropped, a Mac restart taken as a new stream), the windowed bulk path (2 MB with loss, a
  slow transfer kept alive by progress), safe file names, clipboard type filtering; golden fixtures for
  `FileOffer` and `AudioPacket`;
- live: a 5 MB file sent from the phone (`--send-file`) arrived in ~/Downloads with the same SHA-256 while
  streaming; with `CLAMSHELL_TEST_TONE=1` the phone played 218 packets in 5 s with none lost or dropped and
  80 ms queued, through a posture change that rebuilt the virtual display.

**Not verified:** real system audio through ScreenCaptureKit (needs Screen Recording, which the test
pattern run doesn't have; the code path is the same SCStream the video uses), sound on the real Duo's
speaker, the Files picker by hand, Open at login across a restart, keep-awake on AC over a night, the
display waking when the phone connects while the Mac's display is asleep.

**Added**
- Sound: SCK system audio (this app's own sound excluded) → Opus 48 kHz stereo 96 kbit/s, 20 ms packets on
  the unreliable audio channel (`AudioPacket` 0x0401, protocol 1.5) → a 40–120 ms jitter buffer on the phone.
  "Play this Mac's sound on the phone" on the Mac (on by default); "Sound" in the phone's settings and
  Layout menu mutes locally. Audio has its own SCStream, so posture changes don't touch it.
- Files: the share button in the seam bar opens the Files picker; the file goes over the same E2E session
  (`FileOffer` 0x0302 via the windowed bulk path, up to 32 MiB) with a percentage in the seam bar. The Mac
  checks the SHA-256 and writes it to Downloads under a sanitised, unused name, only when "Accept files from
  the phone" is on (off by default).
- Bulk transfers are now windowed (512 chunks in flight, resend after 150 ms, give up after 3 s without
  progress), so large clipboard images and files no longer stall.
- Clipboard: items marked concealed, transient or auto-generated by password managers
  (`org.nspasteboard.*`, 1Password) never leave the Mac; text over 1 MiB and images over 8 MiB are skipped.
- Mac: "Open at login" (`SMAppService`), "Keep this Mac awake while plugged in" (a
  `PreventUserIdleSystemSleep` assertion only while on AC, rechecked every minute), and the display wakes
  (`IOPMAssertionDeclareUserActivity`) when a phone connects.

**Deferred**
- Multi-display (showing a physical display, or a second virtual one): the phone always gets the Clamshell
  virtual display. Input mapping and the cursor assume one display; this needs its own change.
- Cancel for a file in flight: a transfer that stalls gives up by itself after 3 s.
- Files to the phone (Mac → phone); only phone → Mac Downloads.

## M4: Duo postures and hardware input (2026-11-16)

**Verified** (this Mac + iOS Simulator):
- shared suite: posture rules (hinge closed/partial/full × fold horizontal/vertical, fallbacks without a
  hinge), 150/600 ms debounce, flicker never reaches layout, pin override, ⌥-Tab → ⌘-Tab and ⌃-Space →
  ⌘-Space remaps; golden fixtures for `HomeEndpoint` and `DisplayModeRequest`;
- live: streaming in the laptop layout, then `--posture-switch flat` 3 s in: the phone asked for 1335×939, the
  Mac rebuilt the virtual display and encoder, and the phone carried on decoding at the new size in the flat
  layout (picture centred, keyboard below, seam bar at the bottom).

**Not verified (needs the real Duo or hardware):** `UIHingeInteraction` and the division region on a real
fold (the Simulator has no hinge, so it uses the portrait/landscape fallback); the cover-screen glance;
direct touch and edge swipes by hand; a Bluetooth keyboard and mouse through GameController.

**Added**
- `PostureInference` / `PostureDebouncer` (ClamshellInput) and `PostureModel` + `PostureSensor` on the phone:
  hinge status from `UIHingeInteraction`, fold from `reservedRegions(kind: .division, options: .includeInactive)`.
- Layouts: laptop (Mac above the fold, deck below, nothing on the fold), book (Mac on the left page, deck on
  the right), flat (one screen, touch clicks or trackpad over the picture, keyboard on demand, edge swipes
  for Spaces), cover (glance, touch clicks, disconnect).
- Lower-half modes: keyboard + trackpad, side by side, trackpad only, keyboard only. A Layout menu in the
  seam bar pins a posture, picks the mode and the touch mode. `--posture <name>` pins one at launch.
- Direct touch: tap = click, move = drag, hold 0.5 s = right click, two fingers = scroll.
- Hardware keyboard (`GCKeyboard`, HID usages straight through, remaps on by default and switchable) and mouse
  (`GCMouse` raw deltas, three buttons, wheel).
- Protocol 1.4: `DisplayModeRequest`; the Mac rebuilds the display for the posture (docs/protocol.md).
- VoiceOver labels on the screen, keyboard, trackpad and Layout menu.

**Deviations**
- No `ArrangementView`: the SwiftUI split view named in ADR-0012 isn't in the iOS 27.2 SDK, so the layouts
  place the panes around the reported fold themselves.
- No pointer lock: the app is a SwiftUI `WindowGroup`, whose hosting controller doesn't forward
  `prefersPointerLocked`. The mouse still works from raw deltas, but the iOS pointer stays visible over the
  stream.
- Split keyboard is "keyboard and trackpad side by side", not a keyboard split in two halves.
- No new themes or Dynamic Type work: the deck draws its own fixed-size keys, by design.

## M3: pairing and internet paths (2026-11-16)

**Verified** (this Mac + iOS Simulator, no second machine):
- shared suite: XXpsk3 round trip, wrong secret fails at message 3, impostor Mac refused, manual code,
  3-strike lockout, window expiry, reject, codes; pairing over real loopback UDP then an IKpsk2 session
  with the derived key; pause refuses handshakes; WSS alone, UDP blocked → WSS in 0.51 s, UDP preferred when
  both work, UDP blocked mid-stream → WSS within 1 s (0.45–0.76 s), garbage on 443 rejected;
- live: Simulator paired with the host (SAS shown on both, Debug auto-confirm), then streamed with the new
  key; streamed over TCP 443 alone with UDP dead (pill "tcp · 1 ms"); network check LAN 2 ms, UDP 1 ms,
  TCP/TLS 2 ms, with no stream started.

**Not verified:** a real internet path (needs the router forwards, SETUP 4b), the QR camera scan (no camera
in the Simulator), Touch ID (Simulator has none enrolled), NAT-PMP on the VR400.

### Added
- **Pairing (ADR-0014):** Mac menu › Pair new iPhone… (owner password / Touch ID) opens a 120 s window with
  a QR code and a 16-character code; Noise XXpsk3 over LAN UDP only; 6-digit SAS confirmed on the Mac, with
  a warning when two phones answer; 3 failures close the window; 8 phones max. Both sides keep the peer key
  and a `psk_session`; every session is IKpsk2 with it. The dev code (`CLAMDEV1`) is gone from both apps.
- **Devices:** paired-phone list with Revoke (session ends at once), Disconnect all, Pause remote access
  (no sessions, 443 listener closed; LAN pairing still possible).
- **Path P3:** TLS + WebSocket on TCP 443 inside the Mac app, self-signed identity via `/usr/bin/openssl`
  (regenerated yearly). The phone races LAN, home UDP and TCP 443 and moves between them (`PathRacer`).
- **Home endpoint (ADR-0005):** the Mac asks the router for its WAN address over NAT-PMP (read only) every
  10 min, or uses the address typed in the pairing window; IP changes go to a hashed churn log and the menu
  shows "changed N× in 30 days". Protocol 1.3 `HomeEndpoint` tells the phone at each session start and on
  change; pairing hands it over too.
- **Network check** on the phone: one handshake per path, with round-trip times.
- **Phone:** Touch ID before connecting (at most every 5 min; setting, default on), Forget this Mac.

### Deviations from the ADRs (still open)
- The 443 listener runs in the app process, not in a sandboxed XPC helper (ADR-0004).
- Keys are in the Keychain (`ThisDeviceOnly`) but not yet wrapped by a Secure Enclave key; Touch ID gates
  connecting in the app rather than unwrapping the key (ADR-0014). Planned for M6 hardening.
- The pairing secret is 80 bits, not 128, so the QR code and the typed code carry the same value. With a
  120 s window and 3 tries that is still far beyond guessing.
- Router readout over the VR400 admin page (ADR-0005 (a)) isn't built: it needs the router and its admin
  password. NAT-PMP + the manual field stand in. The relay for CGNAT is out of scope (no VPS).
- No XXpsk3 test vector was available offline; the implementation is checked against itself and against
  the existing Cacophony-verified primitives.

## M2: input (2026-11-16)

**Verified:** shared suite green (input: key map, dedupe/redundancy, modifier reconciliation, autorepeat,
click counting, momentum, sticky modifiers, trackpad gestures, bulk transfers; 10 new wire fixtures).
Host and iOS app build; on the Simulator against the local host the deck, trackpad and Accessibility
banner show. **Not yet verified live:** typing and pointing on the Mac, which needs the Accessibility
grant (SETUP step 3.4) and a run on the Duo.

### Added
- **Protocol 1.2** (docs/protocol.md): input channel messages with sequence numbers and redundancy,
  `InputState` heartbeat, `CursorPosition`, `CursorShape`, `ClipboardOffer`, chunked `Bulk` transfers;
  `HostState.inputAllowed`.
- **`ClamshellInput`** (shared): HID → macOS key map, media keys; `InputReceiver` (Mac: dedupe, modifier
  reconciliation, autorepeat with the Mac's key-repeat settings, click counting, scroll momentum, natural
  scrolling, 2 s watchdog); `InputSender` and `StickyModifiers` (phone); `TrackpadInterpreter` (1–4 finger
  MacBook gestures: click, drag, right click, scroll, pinch zoom, Spaces, Mission Control, App Exposé,
  app switcher, look up, show desktop) with pointer acceleration.
- **Mac:** `InputInjector` posts CGEvents (keys with the right flags, media keys, pixel scrolling with
  phases and momentum, gestures through the user's symbolic hotkeys), confined to the Clamshell display;
  menu button for the Accessibility prompt. Client-side cursor: the stream no longer draws the cursor for
  a phone that draws its own; `CursorMonitor` sends each new cursor image once. Optional clipboard sync.
- **Phone:** full MacBook keyboard deck (half-height media/F row, fn layer, inverted-T arrows, caps light,
  haptics, optional sticky modifiers), multi-touch trackpad, locally drawn cursor reconciled with the
  Mac's position, bar under the screen (RTT, stats, send clipboard, keyboard toggle, disconnect). Keys and
  buttons are released when the app leaves the foreground. A narrower phone fits the picture to its width.

### Changed
- Disconnect moved from a 1.5 s long press (it clashed with the trackpad) to the bar's ⊗ button; the HUD
  is off by default (bar's gauge button).

## M1.5: remote paths (cellular, other Wi-Fi) and Mac presence (2026-11-16)

**Verified live on the Duo, home Wi-Fi (2026-11-16):** protocol 1.1 session with rate control, HEVC 4:4:4,
scrolling a window on the Clamshell display at 107 fps, RTT 6 ms, target 15 Mbit/s (it grows only while
the encoder uses it), 3 frames lost to Wi-Fi in the run. The host was started from the command line, not
Xcode (both projects open the local `shared` package and Xcode allows that in one window only).

**Why:** the Duo will often be on LTE or someone else's Wi-Fi, not the home LAN, and the LAN capture
stuck near 30 fps because the Mac's screen saver (Aerial, 30 fps) kicked in, then the lock screen.

### Added
- **Protocol 1.1 (additive):** `ReceiverReport` 0x0011 (phone → Mac every 100 ms: loss, frames lost,
  queuing delay, FEC recoveries, RTT), `HostState` 0x0021 (Mac → phone: locked / screen saver, keep-awake,
  target bitrate, FEC %). Capabilities `receiverReports`, `fecXor`; fragment flag `parity`. A 1.0 phone
  gets the old fixed-rate stream and never sees parity.
- **Rate control** (`ClamshellRateControl`): AIMD on loss and queuing delay, start-up ramp from 8 Mbit/s
  (a LAN reaches the 50 Mbit/s ceiling in ~2 s), floor 1.5 Mbit/s; pacing at ≤ 2.5 × target, capped after
  congestive loss; keyframes paced at half that.
- **XOR FEC:** 1 parity per 10 / 5 / 3 data fragments by measured loss, keyframes doubled; switches off
  after 5 s clean.
- **Keyframe throttle:** ≥ max(100 ms, 3 × RTT); duplicate requests within RTT + 50 ms ignored.
- **Roaming:** the phone's UDP client migrates sockets on a better path or a dead one (Wi-Fi ↔ cellular);
  the Mac already follows the newest authenticated address.
- **Mac presence:** while streaming the host holds a display-sleep assertion (no screen saver, no idle
  lock) and reports lock / screen-saver state; the phone shows a banner.
- **Away from home** on the phone: a manual `host:port` field.
- **`clamshell-netsim`** (tools): a UDP relay with LTE / hotel / bad / congested profiles (delay, jitter,
  bursty loss, drop-tail bottleneck, outages); `tools/scripts/remote-paths.sh` runs host + probe through each.
- Probe: receiver reports, 10 Hz pings, `--v10` (1.0 compatibility), a `PROBE_SUMMARY` line.

### Fixed
- **Keyframe storm with pacing:** the 2-frame send queue dropped encoded P-frames while a keyframe was
  paced out, breaking the reference chain. Now the encoder waits instead (`maxUnsentFrames`).
- **Pong of the transport keepalive (id 0)** was taken as an RTT/clock-sync sample (wrong clock): ignored.
- Reassembler: trailing parity after a chain reset no longer opens phantom frames.

### Known
- netsim (worst-case test pattern, 120 fps full-screen scrolling text): LAN 0 lost / ceiling reached; LTE
  settles at 7–11 Mbit/s of 20, because ±8 ms jitter reads as ~20 ms of queue (threshold tuning pending);
  1–3 % bursty-loss profiles still cost a keyframe per unrecoverable frame (LTR recovery not wired yet).
- Not verified live yet: keep-awake over 20+ idle minutes, a real Wi-Fi → LTE switch, away-from-home via
  the router.

## M1: LAN video (in progress; 2026-11-15)

**Demo state:** the Mac's virtual display streams to the iOS client over real UDP + Noise, found via Bonjour,
1:1 and top-centred, with the HUD. Verified Mac ↔ iOS Simulator, Mac ↔ a command-line client and **Mac ↔ the
Duo over Wi-Fi** (team-signed host with Screen Recording, signed iOS app).

### Added
- **Wire protocol v1.0** (`ClamshellWire`): TLV/LEB128 inner messages, the envelope, Hello/Incompatible
  negotiation, Ping/Pong, Goodbye, KeyframeRequest, **HostStats (0x0020)**, VideoFormat, and VideoFragment
  (fixed 19-byte header). Golden fixtures for every message. See docs/protocol.md.
- **Noise IKpsk2_25519_ChaChaPoly_SHA256** session on CryptoKit (`ClamshellSession`): 29-byte transport
  overhead, 2048-packet replay window, temporary dev pairing code `CLAMDEV1:…` (Mac public key + PSK).
- **Transport** (`ClamshellTransport`): UDP client/server on Network.framework, Bonjour `_clamshell._udp`,
  session drivers.
- **Video path** (`ClamshellVideo`, `ClamshellCodec`, `ClamshellStream`): VideoToolbox HEVC encoder/decoder
  wrappers; SPS chroma check; Main 4:4:4 via `444v` input; fragmenting into 1200-byte datagrams; reassembly;
  never-queue host and client pipelines; damage skip; refinement at 120 ms (QP ≤ 18) and 400 ms (QP ≤ 12);
  keyframe requests with repeat and dedupe.
- **Virtual display** (`ClamshellVirtualDisplay`): private `CGVirtualDisplay` at 939×667 pt / 1878×1334 px
  @ 120 Hz, HiDPI.
- **Keychain store** (`ClamshellKeychain`): this-device-only items; the data-protection keychain on macOS.
- **Mac host app** (`mac-host`, menu bar): virtual display → ScreenCaptureKit → encoder → Noise → UDP. Dev
  code with copy/regenerate, live stats, Screen Recording prompt. Harness A barcode overlay, harness B
  flash square. `CLAMSHELL_TEST_PATTERN`, `CLAMSHELL_EPHEMERAL_KEYS` and `CLAMSHELL_FLASH` switches;
  `bitrateMbps` and `udpPort` defaults.
- **iOS client** (`ios-client`): Bonjour host list, dev-code pairing, the video pipeline, a Metal renderer
  (BT.709 Y′CbCr → BGRA, nearest-neighbour, exactly 1:1 at native scale, top-centred), a 120 Hz display
  link, HUD v1 (fps, Mbit/s, chroma, encode/decode ms, keyframes, refinements, drops, barcode latency),
  NTP-style clock sync, and the HEVC decode probe screen (3 canned clips).
- **Tools:** `clamshell-probe` (encode, crypto, display, client) and `clamshell-bench` (upload,
  text-refine = harness D, harness-b, impair). `tools/bench/harness_b.py` (240 fps clip analysis, with a
  self-test) and `tools/bench/upload_sink.py` (self-hosted upload sink).
- **Harness B on one device:** the iOS client's "Glass-to-glass camera test". The rear camera watches the Mac's
  flash square at up to 240 fps while the screen presents the stream, and both flips are timed on the phone's
  clock. `FlashEdgeDetector` (hysteresis + confirmation), `FlashMatcher` and `FlashSpotFinder` in
  `ClamshellBench` (10 tests). The host's flash square is on the Mac panel (260 pt) and the virtual display
  (160 pt), and a 2 pt dot changing every refresh keeps the Mac panel at full ProMotion rate during the test.
  The client prints one line per matched flip (`# flip up lag … ms · time`) for `devicectl … --console`.
- Host diagnostics behind `CLAMSHELL_CAPTURE_STATS=1`: SCK frame status counts and display-link ticks every
  2 s. Host holds a `.userInitiated + .latencyCritical` activity while streaming. SCK queue depth 3 → 6.
- **Docs:** docs/SETUP.md (from zero), docs/protocol.md, and the M1 probe results in ADR-0006/0007/0008/0010.

### Measured (MacBook Pro M5, macOS 27.2)
- 4:4:4 HEVC encode in hardware: **yes**, only with `HEVC_Main444_AutoLevel` + `444v` input (other pairs fall
  back to 4:2:0 silently). Colour fringe 5.3 → 2.3.
- Encode at 1878×1334: 7.2 ms p50 with low-latency RC (default), 3.4 ms with normal RC.
- Noise seal of a 40 KB frame: 0.10 ms p50 (target < 0.5 ms). Handshake 0.41 ms.
- Virtual display online in ~370 ms; the HiDPI 120 Hz mode applies exactly.
- Harness D: static text ≥ 45 dB at +125 ms after a scroll, at 25 and at 10 Mbit/s (criterion ≤ 150 ms).
- Loopback end to end (test pattern, 50 Mbit/s): connect 6–9 ms, 0 frames lost, capture → decoded
  p50 10.0 ms / p95 12.7 ms (4:2:0) and 10.8 / 20.3 ms (4:4:4).
- Real ScreenCaptureKit capture (team-signed host): ~112 complete frames/s while the Mac is in use; capture →
  decoded (Mac-local client) p50 8.4 ms / p95 11.1 ms, 0 lost. **Open issue:** with the Mac unattended for
  hours, SCK delivered only ~30 complete frames/s (the rest idle) while the overlay ticked at 120 Hz; App Nap,
  draw coalescing, queue depth, display sleep and thermals were ruled out. In use it also dips to ~60/s.

### Measured on the Duo (iPhone19,4, iOS 27.2)
- HEVC hardware decode probe: **4:4:4 passes** (Mac's own `vt444` and x265 samples: 60/60 frames, `444v`
  out, hardware). Burst-fed decode time 13.0–13.5 ms p50 vs 6.1 ms for 4:2:0 (includes queueing).
- Over Wi-Fi (5 GHz ch 36, link-local), 4:4:4: barcode draw → presented on the Duo ~46–48 ms p50.
- Glass-to-glass vs the Mac's own panel (harness B, 384 flips): **p50 15.1 ms**, p75 23.1, p90 76.7,
  p95 87.3 ms. Two modes: 5–25 ms (most flips) and 75–100 ms (~9%). The slow mode is the Wi-Fi link: idle
  ICMPv6 RTT to the Duo is p50 6.0 ms but p90 50 / p99 93 ms; it doesn't follow the SCK capture rate.
  Because the reference is the Mac panel's own visible flip, this is "how much later than looking at the
  Mac", not draw-to-photon.

### Fixed during M1
- A refinement dropped by the encoder was never retried, so text stayed soft. It now retries after 20 ms,
  at most 12 times.
- A duplicate session-start keyframe was sent. Stale requests within 150 ms of a keyframe are now ignored.
- The full-screen scroll dropped ~half its frames at 25 Mbit/s. The LAN default is now 50 Mbit/s.
- iOS: the picture was stretched to the view (the Metal layer was the view's backing layer). It's now a
  sublayer placed at 1:1.
- iOS: a Keychain failure was reported as a pairing/network problem. It now has its own message.

### Not done yet
- The ~30 frames/s capture on an unattended Mac, and the ~60 frames/s dips (see above).
- The Wi-Fi tail: 75–100 ms stalls on ~9% of flips. Candidates: AWDL (active on this Mac) and Wi-Fi power
  save on either side. A direct link (USB) would sidestep it.
- 4:4:4 vs 4:2:0 on the Duo end to end (4:4:4 decode costs more than one 120 Hz frame in the burst probe).
- Upload test: needs a receiver outside the house (the Duo on cellular plus a router port forward), so it moves
  to M3.

## M0: Research and design (Checkpoints 1–2)
- research/ (competitors, protocols, macOS APIs, iPhone Duo) and RECOMMENDATION.md.
- docs/ architecture, security, video, UX, milestones; ADR-0001 … ADR-0017; UI mockups.
