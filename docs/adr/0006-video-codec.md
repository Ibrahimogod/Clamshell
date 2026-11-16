# ADR-0006: HEVC via VideoToolbox; 4:4:4 if the Duo decodes it, else 4:2:0 + refinement

**Status:** Proposed · **Date:** 2026-11-15

## Context
"Sharp text, prioritised over motion." The M5 has hardware HEVC/H.264/ProRes encoders and **no AV1 encoder**. The A20 Pro decodes HEVC, H.264 and AV1 in hardware. Whether it decodes **HEVC 4:4:4** (Range Extensions) in hardware is **unknown**. An M3 Pro on macOS 27.2 *encodes* `HEVC_Main444`. 4:2:0 chroma subsampling smears coloured text and syntax highlighting, which is exactly what VS Code and Xcode are full of.

## Decision
1. **Primary:** HEVC Main 4:4:4 8-bit (`kVTProfileLevel_HEVC_Main444_AutoLevel`), *if* M1's day-1 probe shows the Duo decodes it in hardware at ≥ 120 fps for the laptop-half size (1878×1335).
2. **Fallback A:** HEVC Main 4:2:0 + **refinement frames** (ADR-0008) + **chroma-aware pre-filter**: for static content, upweight chroma QP so coloured text survives.
3. **Fallback B** (only if A looks bad on syntax-highlighted text): an **AVC444-style dual stream**, the way Microsoft RDP does it. Stream 1 is luma + subsampled chroma. Stream 2 encodes the missing chroma samples as a second 4:2:0 picture. The client recombines them in a Metal shader. Cost: 2 encodes and 2 decodes per frame, about +60% bitrate on static text and ~0 on idle.
4. **Compatibility:** H.264 High 4:2:0 for when HEVC fails (it won't on the Duo, but it's needed for the simulator/tests).
5. **Encoder settings (all modes):**
   - `RealTime = true`, `kVTVideoEncoderSpecification_EnableLowLatencyRateControl = true`. Retry without it on `-12902`.
   - `RequireHardwareAcceleratedVideoEncoder`, `AllowFrameReordering = false` (no B-frames), `MaxKeyFrameInterval = ∞` (IDRs only on demand).
   - `kVTCompressionPropertyKey_EnableLTR = true` for loss recovery (ADR-0008).
   - `MaxAllowedFrameQP` and `MinAllowedFrameQP` driven per-frame by the refinement logic.
   - Colour: sRGB/BT.709 tagged as full range, so the Mac's gamma survives. Display P3 handling is checked in M1.
6. **Decode:** `VTDecompressionSession` with `kVTDecompressionPropertyKey_RealTime` and output `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange` or a 4:4:4 equivalent. `IOSurface`-backed buffers go straight to Metal (zero-copy).

## Alternatives considered
- **AV1:** no encoder on Apple silicon, so a software encode at 1878×1335@120 is impossible.
- **ProRes:** hardware on both ends and very sharp, but 80–150 Mbps, far beyond a VDSL upload. *Maybe* a LAN-only "lossless-ish" mode later (M6 experiment).
- **Lossless tile codec (VNC-style):** perfect text when idle, but bursty and CPU-heavy under motion. It could live as a small-damage overlay (caret blink, one changed line). Recorded as an M6 experiment, not a commitment.

## Consequences
- ➕ The best text quality per bit available in hardware on both ends.
- ➖ 4:4:4 encode adds latency: aetherdesk measured ~55 ms vs ~41 ms end-to-end against 4:2:0. **M1 measures this on the M5.** If 4:4:4 costs > 8 ms per frame, use it only for refinement/static frames and stay 4:2:0 while things are moving.
- **Day-1 probe (M1):** decode a canned `Main444` stream on the Duo and report hardware vs software, fps and ms per frame. This one test decides between 1 and 2/3.

## M1 probe results (2026-11-15, MacBook Pro M5, macOS 27.2)
Reproduce with `tools/.build/release/clamshell-probe encode`.

**Encode side: 4:4:4 works in hardware, but only with one exact recipe.** The SPS was parsed for every attempt, because VideoToolbox **silently falls back to 4:2:0** for most profile/input pairs:

| Profile | Input pixel format | SPS chroma | Colour fringe (lower is better) |
|---|---|---|---|
| `HEVC_Main444_AutoLevel` | `444v` (8-bit bi-planar 4:4:4) | **4:4:4** | **2.31** |
| `HEVC_Main44410_AutoLevel` | `x444` (10-bit) | **4:4:4** | 1.97 |
| `HEVC_Main444_AutoLevel` | `x444`, BGRA | 4:2:0 (silent) | 5.5 |
| Main / Main42210 / RExt / any other | any | 4:2:0 | 5.3 |

- So the host converts SCK's BGRA to `444v` itself (`PixelConverter`, a `VTPixelTransferSession`) and checks the SPS of the first frame (`HostVideoPipeline.currentChroma`). The stream description and HUD show what was actually sent.
- 4:4:4 keyframes are ~22% bigger (300 KB against 247 KB at the same QP). Luma PSNR is unchanged (43.4 dB); colour fringing on syntax-highlighted text falls by ~2.3×.
- **Encode latency at 1878×1334, 120 Hz:** low-latency rate control is 7.2–7.3 ms p50 (p95 8.0), against 3.4 ms for normal RC. Normal RC doesn't accept LTR (-12900), and its keyframes are twice the size (400 KB vs 193 KB). **Low-latency RC stays the default.** Its 7.3 ms fits the 8.3 ms frame time, and the never-queue rule absorbs the occasional overrun.
- **4:4:4 end to end on loopback** (host test pattern → real UDP + Noise → decoder; 8 s, 1 s scroll / 1 s still):

| Chroma | Encode ms | Capture → decoded p50 | p95 | Skipped while busy |
|---|---|---|---|---|
| 4:2:0 | 7.19 | 10.0 ms | 12.7 ms | 13 |
| 4:4:4 | 7.22 | 10.8 ms | 20.3 ms | 38 |

  4:4:4 costs **≤ 8 ms per frame**, so under this ADR's rule it stays on for motion, not only for refinement. The p95 regression comes from the BGRA → 444v conversion on the encode queue (more "busy" skips). Moving the conversion off that queue is an M2 item.

**Decode side (the Duo):** **not measured yet.** The iOS app's Probes screen (and `--probe` launch argument) decodes three canned clips with hardware required: a VideoToolbox 4:4:4 clip, an x265 4:4:4 clip and a 4:2:0 control. The iOS Simulator has no hardware HEVC decoder (-12906 on all three, as expected). Until the Duo reports, the client advertises `hevc444Decode` only after a passing probe, so the stream falls back to 4:2:0 + refinement (decision 2) automatically.
