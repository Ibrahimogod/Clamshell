# Architecture Decision Records

Each ADR records one decision: the context, what we chose, what we rejected and why, and what it costs us. Status values: **Proposed** (awaiting your approval at Checkpoint 2), **Accepted**, **Superseded by ADR-NNNN**.

Where a decision overrides something in your original brief, the ADR has a **"Challenges your assumption"** section. Those are the ones to read first.

| ADR | Decision | Challenges your brief? |
|---|---|---|
| [0001](0001-custom-noise-transport.md) | Custom Noise IKpsk2 session over pluggable paths, not WebRTC or QUIC | **Yes**: the brief suggested WebRTC + coturn |
| [0002](0002-path-ladder-and-racing.md) | Path ladder raced in parallel; WSS-on-443 through the system proxy as last resort | — |
| [0003](0003-outer-tls-is-camouflage.md) | Outer TLS is camouflage only; the client accepts any outer certificate | Flags Let's Encrypt as an opt-in outside dependency |
| [0004](0004-home-direct-edge-in-mac-app.md) | Home-direct: the Edge runs inside the Mac app (sandboxed helper); TCP 443 + one random UDP port forwarded | **Yes**: "no inbound ports" and "a server I control on a VPS" |
| [0005](0005-ip-discovery.md) | Learn the home IP on home Wi-Fi + manual fallback; log IP churn | — |
| [0006](0006-video-codec.md) | HEVC via VideoToolbox; 4:4:4 if the Duo decodes it, else 4:2:0 + refinement | — |
| [0007](0007-virtual-display-capture.md) | Capture a private virtual display sized to the phone's exact pixels | Uses a private API (Mac host only) |
| [0008](0008-frame-policy.md) | Drop, never queue; damage skip; refinement frames; fps → bitrate → chroma → resolution degrade order | — |
| [0009](0009-client-side-cursor.md) | Cursor drawn on the phone; Mac reconciles | — |
| [0010](0010-swift-everywhere.md) | Swift 6 everywhere, one `/shared` package; SwiftNIO for the Linux relay | **Yes**: the relay is optional, so `/server` ships later |
| [0011](0011-protocol-versioning.md) | Versioned TLV binary protocol, major/minor, capability negotiation | — |
| [0012](0012-posture-inference.md) | Posture inferred from hinge status + division region + geometry | — |
| [0013](0013-input-model.md) | MacBook-exact deck; CGEvent injection with real trackpad phases; ⌘-Tab strategy | — |
| [0014](0014-pairing-and-keys.md) | LAN-only QR pairing + SAS confirm; Secure Enclave–wrapped keys; Touch ID gate | **Yes**: Face ID → Touch ID (the Duo has no Face ID) |
| [0015](0015-curtain-power-lid-open.md) | Lid-open-on-charger mode: curtain, shield window, power assertions | — |
| [0016](0016-login-window-scope.md) | No pre-login / FileVault access in v1 | Narrows "nice to have" |
| [0017](0017-diagnostics-and-logging.md) | Debug HUD + local-only metrics; minimal logs, no content ever | — |
