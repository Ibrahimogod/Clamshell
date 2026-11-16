# ADR-0008: Drop, never queue; damage skip; refinement frames; degrade fps → bitrate → chroma → resolution

**Status:** Proposed · **Date:** 2026-11-15

## Context
Every queued frame adds a full frame-time of latency (8.3 ms at 120 Hz). Desktop content is mostly static, then changes in bursts. A VDSL upload of ~1–6 Mbps with a deep router buffer (bufferbloat) can add hundreds of milliseconds if we overfill it.

## Decision

### 1. Never queue
Each stage holds **at most one** pending item and drops the older one when a newer one arrives:
- capture → encode;
- encode → send;
- receive → decode;
- decode → present.

Capture (SCK `queueDepth = 3`) delivers only the most recent frame. If the encoder is still busy, the older capture is dropped.

### 2. Damage skip
- When `SCStreamFrameInfo.status == .idle` or the dirty rects are empty, **encode nothing** and send nothing beyond a 1 Hz keepalive.
- The client keeps showing the last frame. The cursor is local (ADR-0009), so it still moves.

### 3. Refinement for text
When the screen goes static for **120 ms**:
- Re-encode the last picture once with a low `MaxAllowedFrameQP` (≈ QP 18). That's a P-frame that only refines residual, typically 20–80 KB.
- Optionally do a second pass at QP ≈ 12 after 400 ms.

Result: motion stays cheap and stills become near-lossless. This is the "text sharp, motion second" priority.

### 4. Loss recovery without IDR storms
- Every N-th frame is marked LTR (`kVTEncodeFrameOptionKey_...` LTR APIs).
- The client ACKs LTRs. On loss it sends a NACK, and the encoder next references the last **acknowledged** LTR, a small P-frame instead of an IDR.
- An IDR is forced only on session start, on a decoder error, or when no ACKed LTR exists.

### 5. FEC
- On UDP paths with RTT > 30 ms *or* measured loss > 0.5%, add Reed-Solomon parity packets per frame: 10–25%, adapted to loss.
- No FEC on LAN (retransmit is cheaper) or on WSS (TCP already retransmits).

### 6. Pacing
Frame packets are paced over ≈ ½ the frame interval rather than sent as a burst. That keeps the VDSL router queue short.

### 7. Rate control
- A **delay-gradient congestion controller** in the style of GCC/BBR, measured from one-way-delay *trends* using a per-packet send timestamp and the receiver's arrival timestamp. Its target is to keep queuing delay under 10 ms.
- The encoder bitrate target follows it each frame, using low-latency rate control's `AverageBitRate` + `DataRateLimits`.
- On WSS, the signal is also the socket's unsent bytes. Above 1 frame's worth, skip encoding.

### 8. Degrade order when bandwidth is short
1. **fps:** 120 → 90 → 60 → 30. Text is unaffected.
2. **bitrate / QP:** motion gets softer, but refinement still sharpens it when the screen stops.
3. **chroma:** 4:4:4 → 4:2:0, when 4:4:4 is active.
4. **resolution:** last resort, at 0.75× and only during motion. Restored at the first refinement frame.

The user can pin "Prefer smoothness" to swap steps 1 and 2.

## Alternatives considered
- **Jitter buffer for smoothness** (WebRTC, Moonlight): adds 20–60 ms. Rejected for desktop work.
- **Periodic IDRs:** wastes 5–10× the bits every interval on static desktops.
- **Resolution-first ABR** (the common streaming default): destroys text first, the opposite of what you asked for.

## Consequences
- ➕ Idle costs nothing. Text converges to crisp within ~150 ms of the screen going still.
- ➖ A more complex sender state machine. It's unit-tested with a deterministic fake encoder and a simulated network in `/shared` tests.
- Budget check: on LAN the target is ≤ 50 ms glass-to-glass; over the internet, ≤ 100 ms with ≤ 65 ms one-way. See docs/video.md.

## M1 findings (2026-11-15)
- **Refinement must retry.** Under low-latency RC, the encoder sometimes *drops* the refinement re-encode (`noData`), and the screen then stays soft until the next change. `RefinementScheduler.refinementDropped` re-arms the same stage after 20 ms, at most 12 times per still period. Harness D (`clamshell-bench text-refine`, 1878×1334): after a scroll, still text reaches ≥ 45 dB PSNR at **+124.6 ms (25 Mbit/s)** and **+125.2 ms (10 Mbit/s)**, best 50.8 dB. **Exit criterion ≤ 150 ms: PASS.** Motion frames sit around 26 dB, which is what refinement is for.
- **Keyframe-request dedupe.** The client asks for a keyframe at session start and repeats every 250 ms until one decodes, so the first keyframe was sent twice. Requests whose `lastGoodFrameId` predates a keyframe sent < 150 ms ago are now ignored. A real loss still gets through on the next repeat.
- **LAN bitrate is 50 Mbit/s.** At 25 Mbit/s, a continuous full-screen scroll made the encoder drop 177 frames in 8 s (low-latency RC drops rather than overshoot). At 50 Mbit/s it dropped 0, and capture → decoded was p50 10.2 ms / p95 13.2 ms. It can be overridden with `defaults write <host bundle id> bitrateMbps -int N`.
- **LTR** is accepted only together with low-latency RC (normal RC returns -12900). Section 4 depends on low-latency RC.
- **Risk for M2/M3 (remote):** the remote video budget is about 60% of home upload. A preliminary `networkQuality` reading was ~16 Mbit/s up at ~10 RPM under load (bufferbloat), so ≈ 9.6 Mbit/s. At 10 Mbit/s, harness D saw 34 of ~60 scroll frames dropped by the encoder. Remote scroll needs the fps step of the degrade order (section 8) from the start, not as a fallback. Re-measure with the self-hosted sink (`tools/bench/upload_sink.py`) before M3.
