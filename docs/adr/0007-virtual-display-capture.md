# ADR-0007: Capture a private virtual display sized to the phone's exact pixels

**Status:** Proposed · **Date:** 2026-11-15

## Context
"Crisp text at 100% zoom on the top half in laptop posture." The laptop top half is **1878 × 1335 px** at 430 ppi. The MacBook's built-in panel is a different size and aspect, so mirroring it means resampling by about 0.62×, which blurs every glyph. Text is only pixel-perfect if the Mac renders a framebuffer of **exactly** the target pixel size and we display it 1:1.

## Decision
1. **Use a virtual display** (`CGVirtualDisplay`, a private CoreGraphics API, used by BetterDisplay, DeskPad and Sidecar-like tools) that the host creates while a session is active. Its modes match the Duo regions **in pixels**:

| Posture | Pixels (WxH) | Default "looks like" (HiDPI 2×) | Optional "more space" |
|---|---|---|---|
| Laptop (top half) | 1878 × 1335 | 939 × 667 pt (pixel-perfect) | 1080 × 768 / 1252 × 890 (macOS-side scaled, still 1:1 on the phone) |
| Flat (landscape) | 2670 × 1878 | 1335 × 939 pt | 1536 × 1080 |
| Book (one half) | 1335 × 1878 | 667 × 939 pt | — |
| Cover (outer, portrait) | 1398 × 2034 | 699 × 1017 pt | — |

   *Scaled modes still stay 1:1 on the phone.* macOS renders at 2× of the "looks like" size and downsamples to the panel's pixels. That's exactly what a MacBook does in its default scaled mode, so the phone still receives panel-sized pixels.

2. **Is 939 × 667 pt too small?** A MacBook Pro 14″ shows ~126 pt per inch at ~50 cm. The Duo's top half shows ~215 pt per inch at ~30 cm. The angular size is ≈ 126/215 × 50/30 ≈ **0.98×**, so text looks about as big as on a MacBook, just with less room. "More space" trades crispness for room, as on a real MacBook.
3. **Layout:** the virtual display becomes the **main display** during a session, so new windows open there. The built-in display stays on behind the curtain (ADR-0015). When the session ends, the virtual display is destroyed and macOS moves windows back.
4. **Posture change → mode change**, applied only after the posture has been stable for **600 ms**, to avoid reflow thrash. A per-posture "Lock layout" setting instead keeps the laptop mode in flat posture and upscales it about 1.42×. Upscaling is soft but readable, and window positions don't move.
5. **Wrapper:** every private-API call sits behind `VirtualDisplayProvider`, with runtime `respondsToSelector:` checks. If it ever breaks after a macOS update, **Fallback 1:** capture the built-in display with ScreenCaptureKit, scale on the GPU with a Lanczos/bicubic filter, and show a "text may be soft" badge. **Fallback 2:** an HDMI/USB-C dummy plug, but that needs EDID-programmable modes for exact pixels.

## Alternatives considered
- **Mirror the built-in panel:** blurry text, and the aspect ratio mismatches, so you get black bars.
- **DriverKit display driver:** no public path for virtual displays.
- **Change the built-in panel's resolution:** wrecks the physical screen and still isn't the right pixel count.

## Consequences
- ➕ True pixel-for-pixel text.
- ➕ 120 Hz capture: virtual display modes declare 120 Hz refresh.
- ➖ A private API, so it's **Developer ID only**, and would need replacing for any Mac App Store version. The iOS app is unaffected.
- ➖ Window rearrangement on session start/end. M4 decides whether to restore window positions ourselves.

## M1 probe results (2026-11-15, MacBook Pro M5, macOS 27.2)
Reproduce with `tools/.build/release/clamshell-probe display`.

- `CGVirtualDisplay` classes are present. A display created at 1878×1334 px, `hiDPI = 1`, 120 Hz comes **online in ~370 ms** and offers 26 modes, including **939×667 pt / 1878×1334 px @ 120 Hz**.
- Selecting that mode works: `NSScreen` reports 939×667 pt, `backingScaleFactor 2.0`, `maximumFramesPerSecond 120`. A display link on that screen ticks 121 times in 1 s.
- **Height is 1334 px, not 1335:** 667 pt × 2. The extra pixel row on the Duo stays black, so the picture is still 1:1.
- Recipe (in `ClamshellVirtualDisplay`):
  - descriptor `maxPixelsWide/High` = the exact pixel size, physical width 150 mm;
  - `hiDPI = 1`, with **one** base mode at the *point* size (939×667 @ 120 Hz). With hiDPI on, macOS adds the 2× variant (939×667 pt backed by 1878×1334 px) by itself, as long as it fits `maxPixels`;
  - the window server starts the display in a 1× mode, so after it's listed, `selectMode()` switches it to the 2× variant.
- **ScreenCaptureKit at 120 Hz on that display: not measured yet.** It needs Screen Recording permission for a stably signed binary (an ad-hoc signature changes on every build, which invalidates the grant). The host app (Developer ID / team-signed) takes this measurement on its first real run. Until then, end-to-end tests use `CLAMSHELL_TEST_PATTERN=1`, which feeds the same pipeline from synthetic frames.
