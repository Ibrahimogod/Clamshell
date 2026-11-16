# Video: targets, measurement, adaptation, sharpness

Related ADRs: [0006 codec](adr/0006-video-codec.md), [0007 virtual display](adr/0007-virtual-display-capture.md), [0008 frame policy](adr/0008-frame-policy.md), [0009 cursor](adr/0009-client-side-cursor.md).

## 1. Targets

| Metric | LAN | Internet (home-direct) | How measured |
|---|---|---|---|
| Glass-to-glass (Mac pixel change → Duo photon), p50 | **≤ 50 ms** | **≤ 100 ms** (if one-way network ≤ 65 ms) | Harness A + B (§2) |
| Input-to-photon (tap on deck → visible change), p50 | ≤ 60 ms | ≤ 120 ms | Harness C |
| Pointer motion latency | ≤ 1 phone frame (8 ms) | same (local cursor) | Harness C |
| Frame rate during scroll | 120 fps | 60–120 depending on bandwidth | HUD presented fps |
| Static text | Refined (QP ≤ 18) within 150 ms of the screen going still | same | Harness D |
| Cold connect from work | — | **< 3 s** to first frame | Client timestamps |
| Recovery after network return | < 1 s | **< 2 s** | `netsim` flap test |
| Dropped/queued frames | 0 queued, ever | 0 queued | Pipeline counters |

### Budget (per frame, 120 Hz)
| Stage | Estimate |
|---|---|
| Capture wait (half a frame) + SCK delivery | 4–5 ms |
| Encode, 4:2:0 / 4:4:4 (M5 HW) | 3–5 / 5–9 ms |
| Seal + packetize + pace (½ frame) | 1 + ≤ 4 ms |
| **One-way network** | LAN 1–3 ms · internet ? (measured) |
| Reassemble + decode (A20) | 3–5 ms |
| Present wait (half a frame) + scan-out | 4 + 4–8 ms |
| **Total** | **≈ 24–40 ms + one-way network** |

## 2. Measurement harness (`/tools/clamshell-bench`, built in M1)

- **A. Capture-to-present (automatic, every session in debug builds):**
  - The Mac draws an 8×8-cell **binary barcode patch** (frame id + Mac monotonic time, mod 2^32) in a 1-pixel-aligned overlay window at the screen corner, included in capture.
  - The phone samples those pixels from the decoded texture in the Metal pass, reads the id, and logs `present_time − mac_time` using a clock offset estimated by NTP-style probes over the session (accuracy ±1 ms on LAN).
- **B. Glass-to-glass (ground truth, one device):**
  - The Mac flips a square black ↔ white every 400–500 ms on its own panel and on the virtual display, in the same main-thread step.
  - The Duo's **rear camera** watches the Mac panel at its fastest rate (240 fps where available) while its screen presents the stream. The camera finds the flashing cell by itself; the renderer reads the square's fixed pixels from each decoded picture.
  - Both become flip times on the phone's own clock (capture timestamps and the display link share `mach_absolute_time`), so no clock sync is involved. Pure logic in `ClamshellBench/FlashTiming.swift`, unit-tested.
  - What it measures: the reference is the flip becoming **visible on the Mac panel**, so the result is how much later the Duo shows a change than the Mac's own screen does. The Mac's own draw → photon time (compositor + panel response) is not in it; harness A's draw → presented number is (on the M1 run: ~47 ms against a camera p50 of 15 ms).
  - The host keeps the Mac panel at its full ProMotion rate during the test (a 2 pt dot changes every refresh); otherwise a still panel shows the flip after a variable delay and the reference jitters.
  - Edge detection uses hysteresis (20% of the swing) and, for the camera, two confirming frames, so a level hovering at the threshold can't pair with the wrong flip.
  - Optional variant: film both screens with a second phone at 240 fps; `tools/bench/harness_b.py` analyses the clip.
- **C. Input-to-photon:**
  - The phone timestamps a deck tap. The Mac overlay inverts a patch on receipt of that input id. The phone measures until it presents the inverted patch.
  - Gives `RTT_input + capture + encode + decode`.
- **D. Text sharpness:**
  - The Mac shows a fixed test page: 11/13/15 px text in SF Mono, coloured syntax, 1-px lines.
  - The phone grabs the decoded texture and computes **PSNR/SSIM vs a lossless reference** captured locally on the Mac at the same moment (sent over a debug LAN channel).
  - Reported at t = 0, 150 and 500 ms after the screen goes still.
- **Network scenarios (`/tools/netsim`):** dummynet/pf profiles on a Mac between the devices:

| Profile | Shape |
|---|---|
| `lan` | — |
| `vdsl-up` | 5 Mbps up, 40 ms, bloat 200 ms |
| `work-443` | UDP blocked + HTTP CONNECT proxy + TLS MITM proxy (mitmproxy) |
| `cell` | 20 Mbps, 60 ms, 1% loss, jitter 15 ms |
| `flap` | link down 5 s every 30 s |

Every PR touching `/shared/RateControl` runs the simulated subset in CI.

## 3. Adaptive bitrate

- **Controller:** delay-gradient (GCC-like) with loss as a secondary signal. The target is a queuing delay under 10 ms.
  - Probes with padding when idle, but only if the user is active, so idle stays at 0 bitrate.
  - Starts at 4 Mbps, ramps to a learned per-network ceiling.
- **Tiers** (also user-pinnable): Text 1–3 · Work 4–8 · Motion 8–15 · Max 20–30 Mbps.
- **Degrade order:** fps → bitrate/QP → chroma (4:4:4 → 4:2:0) → resolution. Resolution is the last resort and only during motion.
- **Upgrade:** additive increase every 500 ms of clean delay. Never raise fps and bitrate in the same step.

## 4. Text-sharpness strategy

1. **1:1 pixels.** The virtual display's framebuffer equals the phone region's pixels. The phone samples with `nearest` filtering at exactly 1:1, with no scaling anywhere.
2. **4:4:4** when the Duo decodes it (probe on day 1), so there's no colour bleed on syntax highlighting.
3. **Refinement frames** 120 ms after the screen goes still (QP ≈ 18), then 400 ms (QP ≈ 12). Static text converges to near-lossless.
4. **Damage skip.** Nothing changed means no new frame, so no recompression drift over time.
5. **Colour fidelity.** Full-range tagging + the correct transfer function: no washed-out greys and no crushed thin strokes.
6. **No cursor in video** (ADR-0009). The I-beam over text doesn't create damage.
7. **Experiment (M6):** a lossless small-damage overlay (zlib/LZ4 tiles ≤ 64×64) for caret blink and single-line edits while the encoder idles.

## 5. Resolution strategy

| Posture | Panel region (px) | Mac mode default | "More space" |
|---|---|---|---|
| Laptop top half | 1878 × 1335 | 939 × 667 pt @2× (pixel-perfect, MacBook-like angular size at ~30 cm) | 1080 × 768, 1252 × 890 (Mac-side scaled, still 1:1 on phone) |
| Flat | 2670 × 1878 | 1335 × 939 pt @2× | 1536 × 1080 |
| Book half | 1335 × 1878 | 667 × 939 pt | — |
| Cover | 1398 × 2034 | 699 × 1017 pt | — |

- A mode change happens only after 600 ms of stable posture, or never, with "Lock layout".
- When bandwidth forces it: encode at 0.75× during motion and decode-upscale with bicubic. Snap back to 1:1 on the refinement frame.

## 6. Audio (M5)
- System audio via SCK, Opus 48 kHz stereo at 64–128 kbps (AudioToolbox `kAudioFormatOpus`; encoder availability verified in M5, otherwise AAC-ELD).
- 10 ms frames and a ≤ 40 ms jitter buffer. Audio may buffer a little; video never does.
