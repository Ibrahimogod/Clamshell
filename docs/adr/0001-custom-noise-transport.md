# ADR-0001: Custom Noise session over pluggable paths (not WebRTC, not QUIC)

**Status:** Proposed · **Date:** 2026-11-15

## Context
We need one end-to-end encrypted session between the phone and the Mac that:
- survives path changes (Wi-Fi → cellular, UDP → TCP fallback) without re-authenticating;
- works when only outbound TCP 443 is allowed, through an HTTP proxy and TLS inspection;
- carries hardware HEVC (ideally 4:4:4) at up to 120 fps with no jitter buffer;
- can't be read or forged by any server in the middle.

## Decision
A custom session layer built on **Noise `IKpsk2_25519_ChaChaPoly_SHA256`**, WireGuard's construction with SHA-256 in place of BLAKE2s so every primitive is in CryptoKit (see "Implementation" below):
- **Static keys:** X25519, exchanged once at pairing (ADR-0014).
- **PSK:** a 256-bit symmetric key also created at pairing. It hedges against a future quantum attacker who records traffic now and decrypts it later.
- **Handshake:** 1 round trip. The responder (the Mac) answers only initiators whose static key is on its allow-list. Message 1 carries a TAI64N timestamp, so a replayed message 1 is rejected.
- **Transport packets:** `type(1) | receiver-index(4) | counter(8) | ChaChaPoly(payload)`. A 2048-packet sliding anti-replay window covers UDP reordering. Rekey happens every 120 s or after 2^60 packets, whichever comes first.
- **Roaming:** the session is identified by receiver index, not by address. An authenticated packet from a new address or path moves the peer's endpoint there, as WireGuard does. No re-handshake.
- **Path-agnostic:** the same encrypted packets ride inside UDP datagrams or WebSocket binary messages (ADR-0002). On a stream path the counter just increments. On a datagram path the window absorbs loss and reordering.
- **Channels inside the session:**
  - video;
  - input, sent redundantly;
  - control, reliable with ARQ;
  - clipboard and files, reliable and opt-in;
  - audio.
  Each channel has its own sequence space and its own reliability mode.

Implementation: Apple CryptoKit (`Curve25519`, `ChaChaPoly`, `SHA256`, `HKDF`). WireGuard uses BLAKE2s, which CryptoKit lacks. SHA-256 is an equally valid Noise hash, so there is no third-party crypto code. The Linux relay never decrypts, so it needs no crypto beyond TLS.

## Alternatives considered

| Option | Why rejected |
|---|---|
| **WebRTC + coturn** (your brief) | Several problems:<br>• Native libwebrtc on iOS has no hardware HEVC encode/decode path and no 4:4:4.<br>• Its jitter buffer and pacing add 30–80 ms that we would have to patch out.<br>• It ignores the system HTTP proxy and PAC files, so it fails exactly on the hostile work network.<br>• TURN-over-TLS has a recognisable DPI fingerprint.<br>• ICE + DTLS + SRTP setup adds 3–6 round trips on every reconnect.<br>• The relay keys are separate from our pairing keys, so "the server can't impersonate" needs extra work. |
| **QUIC (Network.framework) as primary** | A QUIC connection is its own crypto session. It can't continue over a WebSocket when UDP is blocked, so a fallback means a full new handshake and a dropped video stream. Congestion control can't be tuned, and HTTP CONNECT proxies don't carry UDP. |
| **Self-hosted WireGuard + VNC/Screen Sharing inside it** | UDP-only, so it's dead on a 443-only network. It needs the WireGuard VPN app on the phone, which takes over the phone's VPN slot. And Apple Screen Sharing's high-performance mode is gated to Apple-silicon-to-Apple-silicon Macs. |
| **TLS 1.3 + mutual certificates** | TLS ends at whatever box terminates it. A TLS-inspecting proxy or a compromised relay sees plaintext unless we add a second layer anyway. |
| **Signal-style double ratchet** | Built for asynchronous messaging, with per-message key overhead. Noise transport plus a 120 s rekey already gives forward secrecy at the cadence that matters. |

## Consequences
- ➕ One session across every path. Fallback and network change cost zero handshakes, which is key to "recover in < 2 s".
- ➕ We control pacing, FEC and loss recovery, tuned for screen content.
- ➕ The entire security argument fits on one page (docs/security.md).
- ➖ We own the congestion controller, FEC and NACK logic, roughly 2–3k lines of carefully tested code. Mitigation: property-based tests in `/shared` and a dummynet test harness in `/tools`.
- ➖ Custom crypto *composition* (not custom primitives). We follow the Noise spec exactly and test against the official Noise test vectors.
- ➖ App Store: encryption export compliance. This is standard, authentication plus confidentiality of user data under the mass-market exemption. It is a paperwork item in M6.

## Validation plan (part of M1/M3)
- Spike (M1): Noise IK over UDP on the LAN carrying VT HEVC. Measure the added latency (target < 0.5 ms per frame) and CPU use.
- Spike (M3): the same session hopping UDP → WSS → UDP mid-stream. Target: video continues with ≤ 1 IDR and a gap under 300 ms.
- Comparison baseline: a throwaway WebRTC build is not worth the time. Instead we compare against Apple Screen Sharing (high-performance mode is off for this pairing, so standard mode) and Jump Desktop Fluid on the same LAN with the harness from docs/video.md.
