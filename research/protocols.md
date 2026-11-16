# Protocol deep-dive: latency, text sharpness, NAT traversal

Researched 2026-11-15.

## 1. How the best ones get low latency and sharp text

### Jump Desktop Fluid 2.0
Sources: [Connect admin guide](https://support.jumpdesktop.com/hc/en-us/articles/360042490351-Administrators-Guide-For-Jump-Desktop-Connect), [Fluid 2.0 notes](https://changelog.jumpdesktop.com/jump-desktop-with-fluid-2.0-1yMoBG), [4:4:4 notes](https://changelog.jumpdesktop.com/fluid-2.0-beta-2-studio-quality-remote-desktop-with-4-4-4-and-10-bit-color-1IKhva)

- **Transport:** WebRTC (ICE/STUN/DTLS/SRTP). Tries direct first, falls back to Jump's global relays (or self-hosted relays for Enterprise). Relays can't decrypt.
- **Video:** hardware encode and decode, "newer codecs" (a third party says HEVC; unconfirmed), **4:4:4 colour selectable**, 10-bit, **up to 120 fps on ProMotion**, an optional "Retina" mode (sends at the client's native pixel density).
- **Lesson:** a WebRTC-based design *can* hit "smooth + sharp", but Jump owns a heavily customised stack. Fluid 2.0 needed new versions of both the client and the host agent.

### Apple High Performance Screen Sharing
Source: [Apple support](https://support.apple.com/guide/remote-desktop/apdf8e09f5a9/mac)

- Apple silicon on both ends, **4:4:4 chroma**, HDR reference mode, 30/60 fps, stereo audio, virtual displays up to 4K, **UDP 5900–5902**, **75 Mbps recommended for 4K**.
- **Lesson:** Apple's own answer to sharp text is 4:4:4 plus a virtual display sized to the client, and it spends bandwidth freely. It's LAN-oriented, with no traversal.
- A third-party note says HP mode "streams HEVC 4:4:4" ([aetherdesk #44](https://github.com/stormlantern-dev/aetherdesk/issues/44)). Plausible, but not confirmed by Apple.

### Parsec
Sources: [feature matrix](https://support.parsec.app/hc/en-us/articles/4407194154253-Feature-Matrix), [Warp](https://parsec.app/warp)

- Custom UDP protocol (BUD), hardware encode, aggressive frame pacing (present on vsync, drop late frames). 4:4:4 on Windows/NVIDIA hosts.
- **Lesson:** latency comes from **never buffering**. Each frame is independently "late or on time", and late frames are discarded rather than smoothed out with a jitter buffer.

### Sunshine / Moonlight
Sources: [Sunshine](https://github.com/LizardByte/Sunshine), [Lumen fork](https://github.com/trollzem/Lumen)

- RTSP/ENet-based protocol inherited from NVIDIA GameStream. Video over UDP with **Reed–Solomon FEC** per frame instead of retransmission. Hardware encode (VideoToolbox on Mac). Infinite GOP, with IDR/reference invalidation on loss.
- The Lumen fork reports **~1 ms encode-to-network on an M4 Mac mini with H.264 VideoToolbox** (self-reported).
- **Lesson:** FEC beats NACK when the RTT is long (work↔home), because a retransmit costs a full RTT and FEC costs about 10–20% bandwidth.

### RustDesk (read its design)
Sources: [self-host docs](https://rustdesk.com/docs/en/self-host/), [repo](https://github.com/rustdesk/rustdesk)

- Rendezvous (`hbbs`) does hole punching (TCP + UDP 21116); the relay (`hbbr`) forwards TCP. **WSS-only on 443 disables P2P.**
- Crypto is NaCl box. Trust is anchored in the **server's key** distributed to clients. A malicious server operator is inside the trust boundary unless keys are verified out of band.
- Codecs are mostly software VP8/VP9/AV1 with optional HW H.264/H.265.
- **Lesson:** the rendezvous-plus-relay split and the "443-only mode" are the right shape. The trust model is the part we must do better: **pair device keys directly** so the server is never trusted.

### Chrome Remote Desktop
Sources: [Chromium remoting](https://chromium.googlesource.com/chromium/src/+/f303bc03a281b55dbd066185f79daa61dd8ba8d1/remoting/GEMINI.md), [admin help](https://support.google.com/chrome/a/answer/2799701)

- WebRTC with Google's STUN/TURN; VP8/VP9/H.264 (secondary source). Has curtain mode on Mac.
- **Lesson:** WebRTC is proven through corporate networks *when you control TURN at scale*, but CRD's video quality for text is mediocre.

## 2. Codec choice on Apple silicon

| Codec | Mac M5 encode (VideoToolbox) | Duo A20 Pro decode | Text quality | Verdict |
|---|---|---|---|---|
| **HEVC Main 4:2:0 8-bit** | HW, low-latency RC supported | HW (listed) | Good luma; coloured text fringes | **Baseline, always works** |
| **HEVC Main 4:4:4 (RExt)** | HW `HEVC_Main444` / `HEVC_Main44410` offered on M3 Pro / macOS 27.2 ([aetherdesk #44](https://github.com/stormlantern-dev/aetherdesk/issues/44)); **verify on M5** | **UNVERIFIED** | Best: no chroma bleed on syntax-highlighted code | **Preferred if the Duo decodes it** |
| H.264 High 4:2:0 | HW, very fast | HW | Needs ~1.5–2× HEVC's bitrate | Compatibility fallback |
| H.264 4:4:4 (High 4:4:4 Predictive) | Not available in HW on Apple silicon (to the best of public knowledge) | No | — | Rejected |
| **AV1** | **No HW AV1 encoder** on Apple silicon (M3+ have AV1 *decode* only) | HW decode (listed) | Good | Rejected for encode: software AV1 can't hit 120 fps at low latency |

**VideoToolbox low-latency settings** (sources: [WWDC21 10158 Explore low-latency video encoding](https://developer.apple.com/videos/play/wwdc2021/10158/), [FFmpeg low-latency patch](https://ffmpeg.org/pipermail/ffmpeg-cvslog/2023-May/137359.html), [Firefox AppleVTEncoder](https://asuth.searchfox.org/firefox-main/source/dom/media/platforms/apple/AppleVTEncoder.cpp)):

- `kVTVideoEncoderSpecification_EnableLowLatencyRateControl = true` (passed at session creation). Some configs return `-12902`, so probe and fall back.
- `kVTCompressionPropertyKey_RealTime = true`, `AllowFrameReordering = false` (no B-frames), `MaxKeyFrameInterval` very large (IDR on demand only).
- `PrioritizeEncodingSpeedOverQuality` is optional; tolerate `kVTPropertyNotSupportedErr`.
- **Long-term reference (LTR) frames** in low-latency mode (WWDC21) let the receiver ack a good reference so the sender can recover from loss **without an IDR**. That's essential on a lossy relay.
- `DataRateLimits` plus `AverageBitRate` for ABR; or a constant-quality mode for "refinement" frames.

### 4:4:4 fallback if the Duo can't decode it
**Chroma-auxiliary encoding** in the style of RDP's AVC444: send a normal 4:2:0 stream plus, *only for static regions*, a second low-rate stream carrying the missing chroma samples, recombined in a Metal shader. It's more complex, so we only build it if test #1 in iphone-duo.md fails. The cheaper intermediate: **for static frames, send a 4:2:0 frame at 2× chroma resolution** by encoding at 2× size and downsampling luma on the client. That costs bandwidth only while the screen is static, when it's nearly free.

## 3. Damage regions, tiles and full-frame video

| Approach | Pros | Cons |
|---|---|---|
| Full-frame video only | Simple; HW encoder does motion search | Static text is limited by the rate control; small edits cost a frame's overhead |
| Tiles / damage (VNC-style) | Static content is lossless, tiny updates | Poor for motion (scrolling, video); CPU-heavy encodes; the cause of "VNC lag" |
| **Hybrid (recommended)** | Video for motion, plus **refinement** for static | Two code paths |

**Our hybrid:**
1. ScreenCaptureKit gives `SCStreamFrameInfo.dirtyRects` per frame ([Apple docs](https://developer.apple.com/documentation/screencapturekit/scstreamframeinfo)). **No dirty rects means no encode and no send**, so an idle screen costs 0 bits.
2. While content changes, a normal low-latency HEVC frame is sent at the current ABR quality.
3. When a region has been static for about 100–150 ms, send a **refinement frame**: the same frame re-encoded at low QP (near-lossless), as a P-frame referencing the last one. HEVC codes the unchanged parts in almost nothing and spends bits only where the previous quality was low. Text "snaps" crisp about 150 ms after you stop typing or scrolling, like Jump/Parsec "build-to-lossless".
4. A per-region lossless PNG/QOI-tile fallback is **not planned**: the hardware HEVC refinement gets about 95% of the benefit at a fraction of the CPU.

## 4. Frame pacing and rate control

- **Never queue.** At most one frame in flight per stage. The sender drops a new frame if the transport's send buffer holds more than about 1 frame of data (on TCP, measure unsent bytes; on UDP, use our pacer's budget).
- **Client present:** decode as soon as data arrives; present on the next `CADisplayLink` tick; if two frames are decoded before a tick, show the newest.
- **Rate control inputs:** RTT (and its gradient), loss rate, client decode-queue depth, client present lateness. Model it on Google's GCC delay-gradient approach, simplified: back off on rising one-way delay before loss happens, because on a bufferbloated path loss comes too late.
- **Outputs, in priority order** (text-first): (1) fps 120→60→30, (2) bitrate, (3) **resolution last** (resolution changes blur text; fps changes don't).
- **FEC:** XOR/RS parity across a frame's packets on UDP paths with RTT over 30 ms; none on LAN. None on TCP (TCP already retransmits).
- **Cursor:** send the cursor shape and position out of band and **render it on the client**, so the pointer moves at display refresh with zero network latency. The Mac's own cursor is excluded from capture (`showsCursor = false`).

## 5. NAT traversal behind restrictive corporate networks

### Building blocks
- **STUN** finds the reflexive address. **ICE** races candidate pairs. **TURN** ([RFC 8656](https://www.rfc-editor.org/rfc/rfc8656)) relays when direct fails. TURN over TCP/TLS works on 443.
- **Sharing 443 between HTTPS and TURN-TLS:** nginx `stream { ssl_preread }` routes on ALPN `stun.turn` or SNI, or HAProxy `req.ssl_alpn` ([nginx docs](https://nginx.org/docs/stream/ngx_stream_ssl_preread_module.html), [XMPP XEP-0368 wiki](https://wiki.xmpp.org/web/Tech_pages/XEP-0368), [Jitsi TURN guide](https://jitsi.github.io/handbook/docs/devops-guide/turn)). Caveat: TURN clients don't always send ALPN, so keep an SNI rule as well.
- **WebSocket fallback:** HTTP/1.1 Upgrade (or RFC 8441 over HTTP/2) on 443. It looks exactly like a web app. The RustDesk WSS mode is an example.
- **QUIC/HTTP3:** UDP 443. Often blocked or deprioritised on corporate networks (many firewalls block QUIC so it falls back to TCP and stays visible to inspection). Good when it works, never the last resort.
- **HTTP CONNECT proxies:** iOS 17+ `ProxyConfiguration(httpCONNECTProxy:)` attached via `NWParameters.PrivacyContext.proxyConfigurations` ([Apple docs](https://developer.apple.com/documentation/network/proxyconfiguration), [WWDC23 10002](https://developer.apple.com/wwdc23/10002)). There are reports of rough edges: `bad url` errors with HTTP/1.1 CONNECT, and SOCKS being ignored for QUIC ([forum 774682](https://developer.apple.com/forums/thread/774682), [forum 850031](https://developer.apple.com/forums/thread/850031)). **`URLSessionWebSocketTask` honours system proxy and PAC settings automatically**, which makes it the most proxy-robust option on iOS.

### Corporate failure modes and what survives them

| Work-network behaviour | WebRTC + TURN-UDP | TURN-TLS 443 | QUIC 443 | **WSS 443 (via URLSession)** |
|---|---|---|---|---|
| UDP blocked | ✗ | ✓ | ✗ | ✓ |
| Only TCP 443, no proxy | ✗ | ✓ | ✗ | ✓ |
| Explicit HTTP proxy (CONNECT) | ✗ | Partial (libwebrtc native proxy support is limited) | ✗ | **✓ (system proxy/PAC)** |
| DPI app-ID blocks "STUN/TURN" | ✗ | ✗ (ALPN `stun.turn` is a giveaway) | Varies | ✓ (looks like HTTPS) |
| TLS inspection with a CA the phone **doesn't** trust | ✗ | ✗ | ✗ | ✗ with strict validation; **✓ if our security doesn't rely on the outer TLS** (see below) |
| TLS inspection with a trusted CA (MDM phone) | ✗ | ✗ (the proxy can't speak TURN) | ✗ | **✓** (the proxy re-terminates HTTPS but WebSockets pass) |

**Key design insight.** Make the outer TLS **camouflage only**. All authentication and confidentiality lives in an inner end-to-end Noise session keyed by paired device keys. Then:
- a TLS-inspecting proxy can terminate our outer TLS and still see only ciphertext and an HTTP Upgrade;
- a compromised server or a mis-issued certificate gains nothing;
- the TLS certificate can be a self-signed or Let's Encrypt IP certificate. Let's Encrypt has issued **IP-address certificates (6-day, `shortlived` profile, http-01 or tls-alpn-01)** generally since **Jan 15 2026** ([Let's Encrypt](https://letsencrypt.org/2026/01/15/6day-and-ip-general-availability)), which fits your "reach it by IP address" answer.

### WebRTC as the transport: validation of your starting proposal

| Criterion | WebRTC (libwebrtc native) | Custom: Noise session over UDP/TCP paths |
|---|---|---|
| HEVC on iOS native | **Not in libwebrtc's default factory; maintainers had "no plan" for HW HEVC (Mar 2025)**; needs a custom `RTCVideoEncoderFactory` plus an H.265 packetiser. Reports of malformed Apple H.265 RTP payloads ([discuss-webrtc](https://groups.google.com/g/discuss-webrtc/c/NO2j-BhEPO0), [bloggeek](https://bloggeek.me/webrtc-hevc-work-together)) | Direct VideoToolbox NAL units, our framing |
| 4:4:4 | Not negotiable in practice | Yes, when the decoder supports it |
| Frame dropping / no jitter buffer | Fights the built-in jitter buffer and pacer | Full control |
| Refinement frames, LTR, damage-skip | Hard (encoder abstraction) | Natural |
| NAT traversal | **Free (ICE)** | Must build: simple, because we have exactly two endpoints and one server |
| TCP-443 / proxy / DPI | TURN-TLS only; limited proxy support; DPI-visible | WSS via URLSession: proxy-aware, looks like HTTPS |
| E2E with server not trusted | DTLS fingerprints must be signed by device keys (extra work) | Native (Noise IK with pinned static keys) |
| Roaming / instant reconnect | ICE restart ≈ new negotiation (hundreds of ms to seconds) | WireGuard/Mosh-style: authenticated packets from a new address just work |
| Build complexity | libwebrtc build for iOS and macOS (large, C++, painful with Swift 6) | Swift-only, `CryptoKit` + `Network.framework` |

**Conclusion:** WebRTC's one big gift (ICE) is the smallest part of our problem, and it costs us HEVC 4:4:4, frame-level control and proxy robustness. **Recommend the custom design** (details in RECOMMENDATION.md). QUIC (Network.framework) was also considered: it gives connection migration and datagrams, but one crypto session can't span its UDP path and a TCP/WSS fallback, Network.framework doesn't let us tune its congestion control, and proxy support for QUIC is weak. Keep QUIC as a possible future "direct UDP" upgrade.

## 6. Bandwidth model (used for cost estimates)

Panel region in laptop pose ≈ 1878 × 1335 ≈ 2.5 MP. Typical HEVC rates for **screen content** (estimates from public HEVC screen-content behaviour; to be **measured in M1**):

| Quality level | Use | Typical bitrate | GB per hour |
|---|---|---|---|
| Idle / static | Reading code | ≈ 0 (no dirty rects) + refinement bursts | < 0.05 |
| **Text** | Typing, small edits @60–120 fps | 1–3 Mbps | 0.45–1.35 |
| **Work** | Scrolling code, window drags @120 fps | 4–8 Mbps | 1.8–3.6 |
| **Motion** | Video playback @60 fps | 8–15 Mbps | 3.6–6.75 |
| **Max** | Flat 2670×1878 @120 fps motion, 4:4:4 | 20–30 Mbps | 9–13.5 |

1 Mbps sustained = 0.45 GB/hour. Real sessions are mostly idle or text, so a coding hour is likely **0.5–1.5 GB**.

**Hard ceiling: your home upload.** Opensignal's Q2 2026 data puts WE's median **upload at ~6.6 Mbps** (Vodafone ~7.1) ([Opensignal Egypt 2026](https://insights.opensignal.com/2026/09/egypt-at-the-convergence-crossroads-and-what-it-means-for-the-mobile-market/dt)). A 2020 report put VDSL at about 5 Mbps up and FTTH at about 25 Mbps ([r/Egypt](https://lr.in.psf.lt/r/Egypt/comments/gf5zjj/wetelecom_egypt_home_internet_bundles_we_space)). **On a ~6 Mbps upload, "Text" and "Work" fit and "Motion/Max" don't.** The text-first, drop-fps-before-resolution policy exists for exactly this reason.
