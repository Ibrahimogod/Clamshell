# Recommendation: Clamshell architecture (Phase 1 synthesis)

Inputs: [competitors.md](competitors.md), [protocols.md](protocols.md), [iphone-duo.md](iphone-duo.md), [macos-apis.md](macos-apis.md). Your Checkpoint-0 answers: MacBook Pro M5 / 24 GB; **host at home and expose a port on the public IP** if hosting is needed; the input deck should feel exactly like a MacBook keyboard and trackpad; login window is nice to have; personal use, maybe publish later.

## 1. Summary in one paragraph

Build a **custom, path-agnostic, end-to-end encrypted session protocol** (Noise IK with paired device keys, WireGuard-style roaming), **not WebRTC**. Run it over a ladder of paths raced in parallel: LAN UDP, then direct UDP to your home IP, then (optionally) UDP via a relay, then **WebSocket-over-TLS on TCP 443**, which honours the work proxy. Video is **hardware HEVC from VideoToolbox (4:4:4 if the Duo decodes it), captured from a private virtual display sized to exactly the phone's pixels**, with damage-skipping, static "refinement" frames for crisp text, a client-drawn cursor, and frames dropped rather than queued. Because you want to host at home, **the default deployment is "home-direct"**: the phone talks straight to your home public IP on 443, with no VPS detour (lower latency, $0 relay cost). The relay is the same code and can run on a $4 VPS later if CGNAT or a changing IP forces it.

## 2. Architecture

```
                    ┌──────────────────────── HOME ────────────────────────┐
 [iPhone Duo]       │  router :443 ──port-fwd──▶ [Edge]  (TLS 443 + UDP 443)│
  SwiftUI + Metal   │                               │  same Swift module as │
  ─ path racer ─────┼── WSS/TLS 443 (proxy-aware) ─▶│  the VPS relay        │
  ─ Noise session   │── UDP 443 direct ────────────▶│                       │
  ─ VT decode       │                               ▼                       │
  ─ 120 Hz present  │                     [Mac host agent, menu bar]        │
                    │   SCK capture → VT HEVC → Noise → paths               │
                    │   input ← CGEvent; virtual display; curtain; audio    │
                    └───────────────────────────────────────────────────────┘
      optional ↕ (if CGNAT / dynamic IP / you change your mind)
                    [VPS: same relay binary in Docker + rendezvous + auto-TLS]
```

### Where does the Edge run? (two options; your call, Q4 below)
- **E1: inside the Mac host app** (simplest; nothing else to buy). After a reboot, nothing listens until you log in.
- **E2: on a separate always-on box at home** (Raspberry Pi / old Mac, Docker Compose). It survives Mac reboots and can relay to the Mac's SSH for **FileVault remote unlock** (macOS 26+), which unlocks the login-window goal. It costs about $35–80 once.

Either way it's **the same `/server` code** (Swift 6 + SwiftNIO on Linux, Docker Compose), which also deploys unchanged to a VPS.

## 3. Key decisions (and what was rejected)

| # | Decision | Rejected alternatives and why |
|---|---|---|
| D1 | **Custom Noise-based session over pluggable paths** | **WebRTC:** native libwebrtc has no HW HEVC on iOS, no 4:4:4, a built-in jitter buffer we'd fight, weak proxy support, and a DPI-visible TURN-TLS (protocols.md §5). **QUIC primary:** one crypto session can't span its UDP path and the TCP/WSS fallback; untunable CC; weak proxy support for QUIC. **Self-hosted WireGuard:** UDP-only and needs a third-party VPN app on the phone. |
| D2 | **WSS on 443 via `URLSessionWebSocketTask` as the last-resort path** | TURN-TLS (DPI-visible ALPN, no system proxy). Raw TLS (no CONNECT/PAC). |
| D3 | **Outer TLS is camouflage only.** Security lives entirely in the inner Noise session. | Trusting server TLS / tokens, which fails the compromised-VPS and TLS-inspection threats. |
| D4 | **Default: home-direct on port 443** (honours your Q2 answer) | VPS-first: adds two Egypt↔EU legs (estimate +60–120 ms RTT), which likely **breaks the ≤100 ms budget**. Kept as fallback. |
| D5 | **HEVC via VideoToolbox, 4:4:4 if supported, else 4:2:0** + refinement frames | AV1 (no HW encoder on Apple silicon); H.264 (≈2× bitrate; kept as compat); VNC tiles (lag). |
| D6 | **Private `CGVirtualDisplay` sized to the panel region** (laptop ≈1878×1335 px HiDPI) | Native capture + downscale (0.62× resampling, so blurry text; kept as fallback). Dummy plug (kept as lid-closed fallback). |
| D7 | **Client-rendered cursor** + local trackpad acceleration | Server-rendered cursor (one network RTT of pointer lag). |
| D8 | **Drop, never queue** at every stage; fps → bitrate → resolution degrade order | Jitter-buffered smoothness (adds latency); resolution-first ABR (blurs text). |
| D9 | **Swift everywhere** (iOS 27.1, macOS 26+, server on Linux) so `/shared` (framing, crypto, schema) is one Swift package | Go/Rust server (splits the protocol code across two languages). |
| D10 | **Versioned binary protocol** (TLV, `major.minor`; unknown TLVs ignored; major mismatch produces a clean "update the Mac/iPhone app" screen) | Protobuf (adds a dependency and codegen; fine too, but unnecessary). |
| D11 | **Posture from `onHingeChange` + `reservedRegions(.division)` + scene geometry** (no posture API exists) | Hinge angle for layout (Apple explicitly says no). |

## 4. Security model sketch (full version in `docs/security.md` at Phase 2)

- **Pairing (once, at home, LAN only):** the Mac shows a QR code carrying the Mac's static public key, its LAN address and a one-time secret, plus a 6-digit code. The phone scans it and both run a **PAKE-like confirmation** (Noise `XXpsk` with the one-time secret as PSK, then compare the 6 digits). The result: each side stores the other's static public key. **The server never sees the pairing secret.**
- **Keys:** X25519 static keys. The phone's private key is stored in the Keychain (`ThisDeviceOnly`), **wrapped by a Secure Enclave P-256 key** whose access control can require **Touch ID** (the Duo has Touch ID, not Face ID). The Mac uses the Keychain the same way, SE-wrapped.
- **Session:** **Noise IK** (the phone knows the Mac's key). The responder **stays silent** unless the initiator's static key is on its allow-list, so the exposed home port gives scanners nothing: UDP drops, and TCP/WSS returns a generic 404. Transport packets: `session-id | counter | ChaChaPoly(payload)`, a 64-packet anti-replay window, rekey every 2 min or 2^30 packets.
- **Server/Edge knows:** device public keys, pairing state, IP addresses, byte counts. **Never** content. A compromised Edge/VPS can drop or delay traffic (DoS) but **can't read it or impersonate a side**. Phase 2 proves this formally in `docs/security.md`.
- **Mac UX:** menu-bar indicator plus a notification on session start, "Disconnect all" and per-device revoke, optional "approve each new session".

## 5. Video and input pipeline targets

- **Glass-to-glass budget model (per frame):** capture ≈4 ms (½ frame at 120 Hz) + encode 4–8 ms (4:4:4 slower) + crypto/packetize ≈1 ms + **one-way network** + decode 3–5 ms + present wait ≈4 ms + panel ≈4–8 ms ≈ **20–30 ms + one-way network**.
  - LAN (one-way 2–5 ms): **≈25–35 ms**, inside the ≤50 ms target.
  - Work→home direct: **≤100 ms holds if one-way ≤ ~65 ms.** The probe measures this; domestic Egyptian paths are unknown.
- **Measurement harness (M1):** the Mac renders a frame counter as a binary barcode patch; the phone reads it out of the decoded texture and timestamps against a shared clock (NTP-style sync over the session). Also a "photodiode-free" mode: the phone camera films both screens.
- **Input:** trackpad deltas plus client-side acceleration curve, cursor drawn locally immediately, absolute position reconciled from the Mac at 120 Hz. Scrolling forwards gesture phases so macOS sees real trackpad scrolling (elastic and momentum). Keys use HID usage → Mac virtual keycode, with modifier state reconciled on every packet (no stuck modifiers).

## 6. Bandwidth and cost

| Quality level | Bitrate (est.) | GB/hour | **Home-direct cost** | **VPS relay cost** (Hetzner EU: 20 TB/mo included, €1/TB over ([source](https://www.bitdoze.com/hetzner-cloud-cost-optimized-plans/)), outbound counted) |
|---|---|---|---|---|
| Idle / reading | ≈0–0.3 Mbps | <0.15 | $0 | ≈$0 (inside the allowance) |
| Text (typing) | 1–3 Mbps | 0.45–1.35 | $0 | ≈$0; €0.0005–0.0014/h if over the allowance |
| Work (scroll @120) | 4–8 Mbps | 1.8–3.6 | $0 | ≈$0; €0.002–0.004/h over |
| Motion (video @60) | 8–15 Mbps | 3.6–6.75 | $0 | ≈$0; €0.004–0.007/h over |
| Max (flat, 4:4:4 @120) | 20–30 Mbps | 9–13.5 | $0 | ≈$0; €0.009–0.014/h over |

- VPS base: ≈ $4–6/month (Hetzner CX/CAX class; prices moved in mid-2026, so verify). Twenty TB covers more than 2,000 hours a month at "Work" quality, so **bandwidth is effectively free; the VPS fee is the only cost.**
- Home-direct: $0 recurring. **The real constraint is your home upload**: Egypt's measured median is ≈6.6 Mbps up ([Opensignal 2026](https://insights.opensignal.com/2026/09/egypt-at-the-convergence-crossroads-and-what-it-means-for-the-mobile-market/dt)), which supports Text/Work but not Motion/Max. A VPS doesn't change this (the stream still leaves your house once).

## 7. UX direction (Phase 2 detail)

- **Laptop posture (default):** top = Mac at 1:1 pixels; bottom = deck with an **exact MacBook key layout** (your Q3: real proportions, ⌘⌥⌃⇧fn, inverted-T arrows, F-row on swipe) and a **large trackpad** with haptic "click". A split mode puts the keyboard and trackpad side by side.
- **Flat:** full-screen Mac (2670×1878 virtual mode), direct-touch / trackpad toggle, floating mini-keyboard.
- **Book:** Mac left, trackpad right (or Mac spanning both halves).
- **Closed (outer 5.4"):** glance view (Mac online, last session, path quality) plus a **full phone-mode session** (1398×2034 virtual mode).
- Original visual language. No Apple trade dress.

## 8. Risk list

| # | Risk | Severity | Mitigation / when we learn |
|---|---|---|---|
| R1 | **A20 Pro may not HW-decode HEVC 4:4:4** | High (text quality) | M1 probe on day 1; fallback 4:2:0 + refinement, then chroma-aux (protocols.md §2) |
| R2 | **Home upload ≈6 Mbps** caps quality | High | Text-first ABR; tell me your actual upload (Q3) |
| R3 | **CGNAT / ISP blocks inbound 443 / dynamic IP** breaks home-direct | High | Probe from cellular in week 1; fallback: VPS relay (same code) or IPv6; IP change → own-domain DDNS or VPS rendezvous |
| R4 | Work network DPI / TLS inspection specifics unknown | Medium | Outer-TLS-as-camouflage + WSS via system proxy; in-app network probe on day 1 at work |
| R5 | Private `CGVirtualDisplay` breaks on a macOS update | Medium | Thin wrapper; fallbacks: built-in capture + scale, dummy plug |
| R6 | Lid-closed sleep on Apple silicon without a display | Medium | Test `disablesleep` + virtual display; dummy-plug clamshell; must stay on the charger |
| R7 | **No native pointer on the Duo**; `GCMouse` unverified | Medium (hardware mouse only) | Test in M4; fallback AssistiveTouch + hover events |
| R8 | ⌘-Tab / ⌘-Space reserved by iOS | Low–Med | Remaps + deck key; test `GCKeyboard` |
| R9 | Monthly Screen Recording re-prompt; persistent-content-capture entitlement needs Apple approval | Low–Med | Apply; the host warns before expiry |
| R10 | Login-window capture broken on Sequoia+; FileVault pre-boot | Low (nice-to-have) | Tunnel built-in VNC for the login screen; FileVault SSH unlock via home box (E2) |
| R11 | Exposing a home port to the internet | Medium | Stealth Noise IK responder, generic 404, rate limits, only one port, nothing else exposed |
| R12 | App Store (future): review needs a working demo host; export-compliance paperwork for custom crypto | Low | Client uses only public iOS APIs; private APIs stay in the Developer ID Mac host |
| R13 | iOS suspends the app in the background, so the session drops | Low | Cached session tickets give an about 1-RTT resume (<1 s) on foreground |
| R14 | Duo thermals / battery at 120 Hz | Low–Med | Profile in M6; 60 Hz on Low Power / `.serious` thermal state |

## 9. Changes to your starting assumptions (to confirm at Phase 2)

1. **WebRTC → custom Noise transport** (D1–D3).
2. **"No inbound ports" → one forwarded port (443)** by your Q2 answer, with stealth hardening. VPS becomes optional.
3. **"Face ID unlock" → Touch ID** (Duo hardware).
4. **Server language → Swift**, to share `/shared` (D9).
5. **Login window**: realistic only with option E2 (separate home box) or FileVault off.
