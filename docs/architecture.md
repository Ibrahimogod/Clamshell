# Clamshell architecture (Phase 2)

Decisions are in [adr/](adr/README.md). This page shows how the pieces fit, how transport was validated, and how path selection and the debug HUD work.

## 1. Components

```
┌──────────── iPhone Duo (iOS 27.1, SwiftUI + Metal) ─────────────┐
│ PostureModel ── ArrangementView (laptop / flat / book / cover)  │
│ Deck: KeyboardView · TrackpadView · GestureEngine · Haptics     │
│ CursorLayer (local, 120 Hz)     HUD                             │
│ VideoPipeline: Reassembly → FEC → VTDecompressionSession →      │
│                CAMetalLayer (1:1, nearest) @ 120 Hz             │
│ SessionClient (actor) ── PathRacer ─┬─ UDP (Network.framework)  │
│   Noise IKpsk2, channels            ├─ WSS (URLSessionWebSocket)│
│   Keys: SE-wrapped, Touch ID        └─ HTTPS-stream (M6)        │
└───────────────────────────────┬─────────────────────────────────┘
                                │ internet / LAN
           ┌────────────────────▼─────────────────┐
           │ Archer VR400: fwd TCP 443, UDP N     │
           └────────────────────┬─────────────────┘
┌────────── MacBook Pro M5 (macOS 27, Developer ID, menu bar) ────┐
│ ClamshellEdge.xpc  [App Sandbox, no TCC, no keys]               │
│   TLS 1.3 · HTTP/1.1 · WebSocket · 404 responder · rate limits  │
│        │ opaque Noise packets (XPC, shared-memory ring)         │
│ ClamshellHost (main)                                            │
│   SessionServer (actor): allow-list, Noise, channels, roaming   │
│   UDP listener :N, Bonjour _clamshell._udp (LAN)                │
│   Capture: CGVirtualDisplay → ScreenCaptureKit (BGRA, 120 Hz,   │
│            dirtyRects, cursor off)                              │
│   Encode: VTCompressionSession HEVC 4:4:4 / 4:2:0, LTR, RC      │
│   Sender: damage-skip · refinement · FEC · pacing · CC          │
│   Input: CGEvent keys / mouse / scroll phases · hotkey mapping  │
│   Curtain · power assertions · cursor shape feed · clipboard    │
│   Menu bar UI: status, devices, revoke, pause, pair, IP log     │
└─────────────────────────────────────────────────────────────────┘
        (optional, later)  /server  — SwiftNIO relay in Docker Compose (P5)
```

### Monorepo (Phase 3)
```
/shared       ClamshellKit (SwiftPM): Wire, Session, Paths, RateControl, InputModel, Testing
/mac-host     Xcode project: ClamshellHost app + ClamshellEdge.xpc
/ios-client   Xcode project: Clamshell (iOS 27.1)
/server       SwiftNIO relay + Dockerfile + compose.yaml (optional, M6)
/tools        clamshell-bench (latency harness), netsim (dummynet scenarios), keymap-gen, fixture-dump
/docs         ADRs, security, ux, video, SETUP, milestones, CHANGELOG
```

## 2. Session lifecycle

```
phone launch / network change
  └─ Touch ID → unwrap static key
  └─ PathRacer: P1 LAN-UDP (0 ms) · P2 home-UDP (+150) · P3 WSS-443 (+300)
       first to finish Noise IKpsk2 wins (1 RTT on UDP; ~4 RTT on WSS)
  └─ Hello / capabilities (ADR-0011) → display mode for current posture
  └─ Mac: create virtual display (or switch mode) → curtain → IDR → stream
steady state: video ↓, cursor shape ↓, input ↑ (redundant), ACK/NACK ↑, RTT probes ↕
network change: keep session keys → re-race paths → continue (no handshake on UDP)
background: iOS suspends after ~30 s → session idles → foreground: same session if < 120 s
            (keys still valid), else fresh IK handshake (1 RTT)
```

## 3. Transport validation: WebRTC + coturn vs a custom design

Your brief asked for this comparison explicitly. Summary of research/protocols.md §5, scored against *your* requirements:

| Requirement | WebRTC + coturn | QUIC (Network.framework) | **Custom Noise over UDP/WSS (chosen)** |
|---|---|---|---|
| Works with only TCP 443 + HTTP proxy | ⚠️ TURN-TLS; no system proxy/PAC in libwebrtc | ❌ no UDP through proxy; would need a second stack | ✅ WSS via URLSession honours proxy/PAC |
| Survives TLS inspection | ⚠️ DTLS inside TURN-TLS; TURN creds visible to proxy | ❌ | ✅ outer TLS is camouflage; Noise inside |
| Server can't read content | ✅ DTLS-SRTP E2E | ✅ if E2E to the Mac | ✅ |
| Server can't impersonate | ⚠️ needs extra fingerprint pinning via signaling | ✅ with pinned certs | ✅ keys pinned at pairing, no server in the loop |
| HW HEVC 4:4:4 on iOS | ❌ libwebrtc iOS: H.264 HW only; no 4:4:4 | ✅ | ✅ |
| No jitter buffer / drop-never-queue | ❌ built-in jitter buffer + pacer | ✅ | ✅ |
| Seamless UDP ↔ TCP fallback mid-session | ❌ ICE restart (≈1–3 s, new DTLS) | ❌ new connection | ✅ same session, ≤ 300 ms gap |
| Reconnect < 2 s after network returns | ⚠️ ICE restart 1–3 s | ✅ 0-RTT | ✅ 0 RTT on UDP, ~4 RTT on WSS |
| Third-party code size | ~1M+ LOC libwebrtc | 0 | ~3–5k LOC of ours |
| Effort | Medium (glue) + high (fighting defaults) | Medium | Medium–high (CC, FEC ours) |

**Verdict:** a custom design. WebRTC fails three hard requirements: the proxy, hardware 4:4:4, and no jitter buffer. QUIC fails the 443/proxy fallback. The cost is that we own congestion control and FEC, which M1 to M3 test with `/tools/netsim`.

**Validation in Phase 3, not just on paper:**
- M1, LAN: Noise over UDP adds < 0.5 ms per frame (measured).
- M3: block UDP with `pfctl` while streaming. Video must continue on WSS within ≤ 300 ms of the switch, and cold connect on a "443-only + proxy" `netsim` profile must take < 3 s.
- M3: from real cellular, and once at work with the Network check.

## 4. Automatic path selection

- **Inputs:** NWPathMonitor (interface, expensive or constrained, SSID hash), path memory per network, live probes.
- **Score while multiple paths are alive:** `score = RTT_p50 + 4·jitter + 200·loss% + penalty(TCP: +15 ms)`. Switch only when the new score beats the old by > 20% for 2 s (hysteresis). Never switch during a drag or a keypress burst. Wait for 300 ms of idle input, up to a 3 s maximum.
- **Low Data Mode / cellular "expensive":** cap at the "Work" bitrate tier unless overridden.
- **Diagnostics:** the Network check screen (docs/ux.md §7) runs each path in turn and reports reachability, RTT, proxy detection (`CFNetworkCopySystemProxySettings`) and TLS-inspection detection (outer cert ≠ our self-signed fingerprint, or issuer ≠ LE).

## 5. Debug HUD

See ADR-0017 for fields. Shown in every mockup as a toggle. Layout: a translucent capsule in the top-left of the Mac view. Expanded, it is a 2-column panel with sparklines:

```
WSS·443  proxy✓  TLS-inspected✓     RTT 38 ms (p95 61)   loss 0.0 %
120/118/118 fps   6.2 / 8.0 Mbps    HEVC 4:4:4 1878×1335  refined ●
drop  net 0 · late 2 · dec 0        enc 5.1 ms · dec 3.4 ms   g2g ≈ 62 ms
thermal nominal · 2.1 W
```

## 6. Cost

There is no recurring cost in the default deployment: home-direct, Edge in the Mac. Bandwidth per hour is in research/RECOMMENDATION.md §6. The ceiling is your **home upload**. "Text" (1–3 Mbps) and "Work" (4–8 Mbps) fit a typical VDSL upload; "Motion" and "Max" probably don't. M1 measures your real upload. The optional VPS (P5) adds ≈ $4–6 a month, with bandwidth effectively free inside a Hetzner 20 TB allowance.
