# Competitor teardown

Researched 2026-11-15. Sources are linked inline. Review counts for the new Duo-era apps are tiny (4–12 ratings), so treat complaint patterns as signals rather than statistics. Where a listing doesn't state something, the cell says **not stated** instead of guessing.

## 1. New iPhone Duo-era apps

### Pocket Mac Lab (Declann Tan)
Source: [App Store listing](https://apps.apple.com/us/app/pocket-mac-lab/id6826478625)

| Aspect | Finding |
|---|---|
| Price | $5.99 paid up front, "No subscriptions or in-app purchases". #5 Top Paid Productivity. |
| Mac side | Free notarized "Pocket Mac Connector". Needs Screen Sharing, Screen & System Audio Recording and Accessibility. The listing contradicts itself: "macOS 15 or later" in the description, "macOS 14 + M1 or later" in Compatibility. The Mac must stay awake and signed in, and "a local sign-in may be needed after restart". |
| Connection | "Pair once, reconnect from home or another network". No transport details. Pairing uses the **Mac account login** plus code approval on the Mac. |
| Codec / fps | Not stated. "Performance depends on your devices and networks". |
| Input | Touch, on-screen keyboard, trackpad mode, a "ridged scroll wheel", pinch zoom, two-finger pan, BT/USB keyboard and mouse. |
| Duo-specific | Themed keyboards and "covers"; laptop-like fold. Also bundles unrelated mini apps (calculator, games, photo filters). |
| Privacy | Remembered passwords in device-only Keychain; revoke from the companion. Privacy label: diagnostics only. |
| Reviews | 2.8★ (12). Complaints: "absolutely refuses to connect… waste of money", Apple-silicon only. Praise: fast wake and reconnect, responsive developer (via Instagram DMs). |

### DuoBook: Pocket Mac (Mehdi Chitsaz)
Source: [App Store listing](https://apps.apple.com/us/app/duobook-pocket-mac/id6826643457)

| Aspect | Finding |
|---|---|
| Price | Free. "DuoBook Classics" $3.99 one-time, plus tips. |
| Mac side | Free "DuoBook Host", macOS 14+, Screen Recording + Accessibility. |
| Connection | Bonjour on LAN. Remote access "sets up most home routers automatically" (**UPnP**, which our constraints forbid) and keeps the Mac's address in the user's **iCloud**. Release notes mention a relay plus data-saver modes for cellular and VPN. |
| Codec / fps | Up to 120 fps on Wi-Fi when both ends support 120 Hz (Auto/120/60/30). Codec not stated. |
| Input | Mac-laptop keyboard with modifiers and a Touch ID key; trackpad with tap-to-click, two-finger right-click, momentum, pinch, 3- and 4-finger swipes; BT keyboard; direct touch. |
| Duo-specific | Layout follows the hinge (laptop mode, or flat with a big trackpad). The closed outer screen acts as a customizable "lid". |
| Privacy | "Data Not Collected", no account, no analytics, E2E-encrypted claim. |
| Reviews | 3.5★ (10). The visible reviews are positive; a 1★ has no visible text. |

**Takeaway:** the closest competitor to what you want. It falls short on your constraints in three places: UPnP, iCloud-based discovery, and an unspecified relay.

### Headroom: Remote Desktop (MusicFlow / Haruhiko Kishi)
Sources: [App Store](https://apps.apple.com/us/app/headroom-remote-desktop/id6790331904), [Digital Trends](https://www.digitaltrends.com/computing/slug-headroom-iphone-duo-control-mac/), [TechRadar hands-on](https://www.techradar.com/phones/iphone/the-iphone-duo-has-transformed-how-i-code-with-my-mac-and-this-game-changing-app-unlocked-its-productivity-potential)

| Aspect | Finding |
|---|---|
| Price | Free with a 10 min/day limit (was 3). Pro $14.99 one-time. |
| Mac side | Nothing for the basic mode: it talks **VNC to macOS's built-in Screen Sharing**. The optional "Headroom Link" Mac app adds audio and screen-shape matching. |
| Connection | Bonjour or IP on the LAN. For the internet it **recommends Tailscale**. No relay. |
| Codec / fps | **ZRLE** (classic VNC encoding) with Metal rendering. No fps stated. |
| Input | Tap to click, long-press drag, two-finger scroll, pinch, control-bar trackpad, sticky or locked modifiers, dictation, 3-finger Mission Control (v1.5). |
| Duo-specific | Laptop pose puts the Mac on top and the keyboard below; flat spans the screen; nothing is drawn across the fold; the bottom half can be a trackpad. |
| Reviews | 4.0★ (4). "Lag is really bad but very cool". A stuck-modifier bug. The time limit is too short to evaluate the app. A key button could paste a saved password by accident. |

### Astropad Workbench
Sources: [9to5Mac 1.4](https://9to5mac.com/2026/10/27/astropad-workbench-1-4-adds-terminal-access-iphone-duo-support-and-more/), [MacRumors launch](https://www.macrumors.com/2026/04/08/astropad-workbench-app/), [Astropad blog](https://astropad.com/blog/workbench-vs-teamviewer/)

| Aspect | Finding |
|---|---|
| Price | Free 20 min/day. Unlimited **$14.99/mo or $79.99/yr** (up from $10/$50 at launch). |
| Mac side | macOS 15+, Workbench app. |
| Connection | **Vendor account** (same account on both devices); "global relay network", 11 regions; AES-256 E2E claim. |
| Codec | Proprietary **LIQUID** codec (Luna Display lineage). fps not stated. |
| Duo-specific | v1.4 "runs natively on iPhone Duo", agent pane plus the rest of the phone. Layouts not described. |
| Extras | Built-in terminal (persistent sessions), voice input, AI-agent monitoring. |

### Remote Desktop by Threadmark
Sources: [threadmark.ai](https://threadmark.ai/), [Google Play](https://play.google.com/store/apps/details?id=com.threadmark.remotedesktopclient&hl=en_US)

No subscription. Free host for Mac and Windows. Claims "no screen relay", with traffic flowing directly between devices. The Play listing says both devices need **the same Apple Account**. Codec, fps and Duo features: **not stated**. Upcoming "local AI" natural-language control.

### Tomaco
Source: [tomaco.app](https://tomaco.app/) (search-result excerpt; the site fetch failed)

macOS 14+ on Apple silicon; iOS 16+. LAN, or remote **via Tailscale**. Claims up to 5K, 120 Hz ProMotion, audio passthrough and "peer-to-peer encryption". Pro is a one-time purchase. Pairing code plus approval on the Mac.

### ReMac (Rudy Saad)
Sources: [App Store (GB)](https://apps.apple.com/gb/app/remac/id6767737162), [remac.tech](https://www.remac.tech/)

Free on the LAN. **ReMac Cloud subscription** ($2.99/mo, $24.99/yr) for a relay from other networks. QR pairing; the site says it signs in with **the same Apple account**. Trackpad, iPhone keyboard, file browser, multiple Terminal sessions. Privacy label links email, name and device ID. No Duo features. Not enough reviews to show.

### Maccess (Maira Akram)
Source: [App Store](https://apps.apple.com/us/app/maccess/id6774586700), [maccess.io](https://maccess.io/)

Free on the LAN. Pro **$4.99/mo or $39.99/yr** for remote access over a **cloud relay**; Pro+ $9.99/mo. AI credit packs. Sign in with Apple. QR plus passcode pairing to the "Maccess Helper" menu-bar app (macOS 14–15.6+, M1+). Privacy label links contact info, audio and user content. No Duo features listed.

### DeskBridge
There is no App Store product by this name. The closest is [jasonvnit/deskbridge](https://github.com/jasonvnit/deskbridge), a self-hosted browser-based Mac control project that relies on **Cloudflare Tunnel** (a forbidden dependency here). A different "DeskBridge" on InsanelyMac is Mac-to-Mac keyboard sharing. **If you meant a specific app, send me the link.**

### Open-source Duo projects worth reading (not competitors)
- [xav1erwang/DuoDesk](https://github.com/xav1erwang/DuoDesk): native Mac remote desktop for iPhone Duo with keyboard and trackpad; requires macOS 27.
- [jacobcxdev/duo-workspace](https://github.com/jacobcxdev/duo-workspace): remote desktop plus second display for Duo and iPad over LAN or VPN; separate host app.

## 2. Established apps

### Jump Desktop (Fluid protocol)
Sources: [App Store](https://apps.apple.com/us/app/jump-desktop-rdp-vnc-fluid/id364876095), [Connect admin guide](https://support.jumpdesktop.com/hc/en-us/articles/360042490351-Administrators-Guide-For-Jump-Desktop-Connect), [Fluid 2.0 4:4:4 notes](https://changelog.jumpdesktop.com/fluid-2.0-beta-2-studio-quality-remote-desktop-with-4-4-4-and-10-bit-color-1IKhva), [Teams security paper](https://JumpDesktop.com/docs/JumpDesktopTeamsSecurityPaper.pdf)

- $14.99 one-time on iOS. Some features (pen pressure, 10-bit) are tied to **Teams/Enterprise subscriptions**.
- Jump Desktop Connect on the host; a jumpdesktop.com account for automatic setup.
- Fluid uses **WebRTC** (STUN/DTLS/SRTP), direct first, with "global relays" as fallback. Jump states that relays cannot decrypt the traffic. Enterprises can self-host relays.
- Fluid 2.0: newer codecs with full hardware encode and decode; **4:4:4 color for everyone** ("Color Quality > High"); 10-bit for Enterprise; **up to 120 fps on ProMotion** devices; optional Retina mode.
- Input: physical mouse, Bluetooth keyboard, Pencil, gamepad mode, gestures. **⌘-Tab can't pass through on iOS**, so Jump maps ⌥-Tab to ⌘-Tab ([support thread](https://support.jumpdesktop.com/hc/en-us/community/posts/360073755232/comments/360013146372)).
- Complaints: occasional disconnects, subscription gating. One forum user saw Fluid stay on a relay on the same LAN ([thread](https://support.jumpdesktop.com/hc/en-us/community/posts/36881941179789/comments/36907284622989)).
- **This is the benchmark for "smooth + sharp"**, and it's the design closest to the transport you proposed.

### Screens 5 (Edovia)
Sources: [Screens 5.10 blog](https://blog.edovia.com/en/screens-5.10-high-performance-screen-sharing), [MacStories](https://www.macstories.net/reviews/screens-5-10-brings-apples-high-performance-screen-sharing-to-iphone-and-ipad/), [9to5Mac](https://9to5mac.com/2026/11/10/screens-5-10-adds-two-highly-requested-remote-desktop-features/), [Screens site](https://edovia.com/en/screens)

- VNC client. 5.10 (Nov 2026) is the **first third-party client to speak Apple's High Performance Screen Sharing**: HEVC, remote audio, dynamic desktop resizing, "display privacy". No Mac software needed.
- HP mode needs an Apple-silicon host, macOS 14+ and a fast, low-latency link. It falls back to standard updates when the network degrades.
- Remote access uses the **Screens Connect account** or Tailscale integration.
- Duo: works on inner and outer displays; resizing to the new canvas "takes a couple of seconds"; the desktop on the outer display is "very small".
- iOS reserves ⌘-Tab, so Screens offers ⌘/⌃ swap or ⌘-\ ([help](https://help.edovia.com/en/screens-5/features/permute-cmd-ctrl-alt-tab)).

### Apple Screen Sharing, High Performance mode
Source: [Apple: Use High Performance screen sharing](https://support.apple.com/guide/remote-desktop/apdf8e09f5a9/mac), [9to5Mac guide](https://9to5mac.com/2026/02/05/how-to-use-macos-high-performance-screen-sharing-for-lower-latency-and-better-color-video/)

- **Mac-to-Mac only** from Apple (Screens 5.10 now speaks it from iOS). Both ends Apple silicon, macOS 14+.
- Stereo audio, HDR reference mode, **4:4:4 chroma**, 30/60 fps, virtual displays up to 4K.
- **75 Mbps recommended for one 4K display**, wired preferred, UDP 5900–5902. One HP session per Mac.
- It's a LAN/VPN technology. It doesn't do NAT traversal, which makes it useless from a hostile work network without a tunnel.

### Chrome Remote Desktop
Sources: [Google admin help (curtain mode)](https://support.google.com/chrome/a/answer/2799701), [Chromium remoting source](https://chromium.googlesource.com/chromium/src/+/f303bc03a281b55dbd066185f79daa61dd8ba8d1/remoting/GEMINI.md), [architecture write-up (secondary)](https://sameer-naik-blogger.blogspot.com/2025/09/inside-chrome-remote-desktop.html)

Free. **Google account** required. WebRTC with STUN/TURN through Google infrastructure; VP8/VP9/H.264 (secondary source). Has a **curtain mode** on Mac (`RemoteAccessHostRequireCurtain`). The input model is weak on mobile, and it has no Duo features.

### RustDesk (open source)
Sources: [self-host docs](https://rustdesk.com/docs/en/self-host/), [GitHub](https://github.com/rustdesk/rustdesk)

- Free OSS, plus a paid Pro server. **The only established option that is fully self-hostable today.**
- `hbbs` (ID/rendezvous) and `hbbr` (relay). Ports TCP 21115–21117, TCP+UDP 21116, WebSocket on 21118/21119. **You can expose only TCP 443 with a WSS relay, but then P2P is disabled.**
- Hole punching via the rendezvous server first, relay on failure.
- Crypto is NaCl-based (Curve25519/Ed25519). Its trust anchor is the **server's public key** configured in clients, so security depends on the rendezvous server, which the user may not fully control ([secondary analysis](https://wz-it.com/en/blog/self-host-rustdesk-2026/)). That is weaker than our requirement that the server must not be able to impersonate either side.
- Software-leaning codecs (VP8/VP9/AV1 plus optional HW H.264/H.265). No Duo UX. The iOS client is generic.

### Parsec
Sources: [macOS hosting preview](https://parsec.app/blog/macos-hosting-preview-available-now), [feature matrix](https://support.parsec.app/hc/en-us/articles/4407194154253-Feature-Matrix), [iOS not supported](https://support.parsec.app/hc/en-us/articles/4425688194189)

The best-in-class low-latency game streamer, but **there is no official iOS/iPadOS client** ([OpenParsec](https://blog.brightcoding.dev/2026/04/09/openparsec-transform-your-ipad-into-a-gaming-powerhouse) is a community client). Mac hosting exists, with 4:4:4 and virtual displays historically limited on Mac. Account required. Disqualified for this use, but worth studying for its frame pacing.

### Moonlight + Sunshine
Sources: [Sunshine](https://github.com/LizardByte/Sunshine), [macOS install issues discussion](https://github.com/orgs/LizardByte/discussions/777), [Lumen macOS fork](https://github.com/trollzem/Lumen)

Open source, LAN-first game streaming. Sunshine supports a macOS host via VideoToolbox, but macOS support has been rough (install and permission issues; forks like Lumen "fix macOS from the ground up"). Moonlight iOS is excellent for latency but **game-oriented**: no text-sharpness strategy, weak desktop input, and no NAT traversal beyond manual port forwarding.

## 3. What users hate

| Pain | Evidence | Who suffers from it | Our answer |
|---|---|---|---|
| **Won't connect / flaky setup** | Pocket Mac Lab "refuses to connect"; Jump "occasionally lose connections" | Pocket Mac Lab, Jump, all Tailscale-dependent apps | One path ladder (LAN, direct, relay UDP, TCP 443) raced in parallel; a probe screen that says exactly what's blocked |
| **Lag** | Headroom "lag is really bad"; VNC/ZRLE apps in general | Headroom, Pocket Mac Lab (unknown codec) | HW HEVC, local cursor rendering, never queue frames, 120 Hz present |
| **Needs a third-party VPN for remote access** | Headroom, Tomaco, Screens recommend Tailscale | Headroom, Tomaco, Screens | Built-in, self-hosted rendezvous and relay |
| **Vendor account / Apple ID / iCloud** | Workbench, Maccess, ReMac, Threadmark, DuoBook (iCloud), Chrome RD, Parsec | Most of them | Device-key pairing only. No accounts. |
| **Subscriptions** | Workbench $14.99/mo, Maccess $4.99–9.99/mo, ReMac Cloud, Jump Teams gating | Workbench, Maccess, ReMac, Jump | N/A (personal); the server costs $0–5/mo |
| **Daily time limits on free tiers** | Headroom 10 min, Workbench 20 min | Headroom, Workbench | N/A |
| **Blurry text** | VNC scaling, full-desktop downscale to a phone panel | VNC-based apps, anyone streaming 4:2:0 | Virtual display sized to the panel (1:1 pixels), 4:4:4 where the decoder allows, static refinement frames |
| **Tiny desktop on a small screen** | Screens on the Duo outer display is "very small" | Screens, and anyone mirroring the native resolution | HiDPI virtual display per posture, plus a cursor-following zoom lens |
| **Slow resize when folding** | Screens resize "takes a couple of seconds" | Screens | Pre-create a virtual display mode per posture; switch the encoder crop instantly, then resize the display in the background |
| **⌘-Tab / ⌘-Space captured by iOS** | Jump and Screens both document workarounds | All iOS clients | ⌥-Tab to ⌘-Tab remap, an on-deck ⌘-Tab key, test GCKeyboard (see iphone-duo.md) |
| **Stuck modifiers** | Headroom bug | Any app with sticky modifiers | Modifier state is authoritative on the Mac side, released on disconnect or background |
| **Data collection / privacy labels** | Maccess and ReMac link name, email, IDs | Maccess, ReMac | No data collected; the server stores only public keys |
| **Apple-silicon-only hosts** | Pocket Mac Lab complaint | Many | Not an issue: you have an M5 |
| **No login window after reboot** | Pocket Mac Lab "local sign-in may be needed after restart" | Most | Stretch goal; see macos-apis.md (FileVault SSH unlock, loginwindow agent) |

## 4. Features worth matching or beating

| Feature | Best today | Bar to beat |
|---|---|---|
| 120 fps on ProMotion | Jump Fluid 2.0, DuoBook, Tomaco | 120 fps **when the network allows**, adaptive down to 30, with a visible HUD |
| 4:4:4 chroma for text | Jump Fluid 2.0, Apple HP mode | 4:4:4 HEVC if the A20 Pro decodes it, otherwise a 4:2:0+chroma-refinement fallback, plus lossless static refinement |
| Dynamic resolution / virtual display | Apple HP, Screens 5.10 | Per-posture virtual display with **instant** switching |
| Display privacy / curtain | Apple HP, Screens, Chrome RD | Curtain while a session is active (see macos-apis.md) |
| Laptop-pose split UI | DuoBook, Headroom | Posture-native deck built on the iOS 27.1 `ArrangementView`/`ReservedRegion` APIs, with the outer display as a "lid" |
| Mac-laptop keyboard + trackpad | DuoBook | Exact MacBook layout (your Q3 answer), Force-Touch-like click, momentum, 3/4-finger gestures, haptics |
| Remote audio | Jump, Screens HP, Tomaco, Headroom Link | Opus audio, synced to video |
| No-account pairing | Headroom (VNC), DuoBook (6-digit code) | QR + short code, **mutual device keys**; the server can't impersonate either side |
| Self-hosted relay | RustDesk, Jump Enterprise | Single small server, home or VPS, **E2E with pinned keys**, TCP 443 fallback through proxies |
| Terminal / agent pane | Workbench 1.4, ReMac | Out of scope for M1–M6; candidate for later |
