# Mac-side APIs

Researched 2026-11-15. Your Mac: **MacBook Pro M5, 24 GB**. It shipped with macOS 26 Tahoe; **macOS 27 "Golden Gate" was released 14 Sep 2026** ([9to5Mac](https://9to5mac.com/2026/06/08/apple-announces-macos-golden-gate-27/), [MacRumors](https://www.macrumors.com/roundup/macos-27/)). Target: **macOS 26+**, tested on whichever you run (open question).

## 1. ScreenCaptureKit (video and audio)

Docs: [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit), [SCStreamConfiguration](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration), [SCStreamFrameInfo](https://developer.apple.com/documentation/screencapturekit/scstreamframeinfo), [WWDC22 10155 *Take ScreenCaptureKit to the next level*](https://developer.apple.com/videos/play/wwdc2022/10155/), [WWDC23 *What's new in ScreenCaptureKit*](https://wwdcnotes.com/documentation/wwdc23-10136-whats-new-in-screencapturekit/)

- **Per display:** `SCContentFilter(display:excludingWindows:)`. We capture exactly one display (the virtual one, see §4).
- **Pixel format:** `kCVPixelFormatType_32BGRA` when feeding a 4:4:4 encode (VT converts BGRA to 4:4:4 internally, as confirmed in the aetherdesk probe). `420v` is enough for the 4:2:0 path.
- **Frame rate:** `minimumFrameInterval = CMTime(1, 120)`. It's a ceiling, not a guarantee; developers report throttling and idle frames ([forum 811300](https://developer.apple.com/forums/thread/811300)). **Idle frames are useful**: `SCFrameStatus.idle` means nothing changed, so we skip encoding.
- **Damage:** `SCStreamFrameInfo.dirtyRects` per sample buffer. It drives "skip unchanged" and the static-refinement timer.
- **Latency:** `queueDepth` 3 (the minimum; one hang at 3 has been reported, so test 3 vs 4). `displayTime` attachment (mach ticks) for capture-latency measurement.
- **Cursor:** `showsCursor = false`. We ship the cursor image (`NSCursor.currentSystem` / CGS cursor shape notifications) out of band and render it on the phone.
- **HDR:** `captureDynamicRange` exists (macOS 15+). **Not needed**: SDR keeps text crisp and the bitrate low.
- **Audio:** `capturesAudio = true`, `excludesCurrentProcessAudio = true`, 48 kHz stereo, encode with Opus (libopus) or AAC-ELD (`AudioConverter`, low delay). Opus is preferred for loss resilience.
- **Permission:** "Screen & System Audio Recording". Since Sequoia, users get **periodic re-approval prompts** (weekly in betas, **monthly** at release) ([TidBITS](https://tidbits.com/2024/08/19/apple-reduces-excessive-sequoia-permission-requests-shifts-to-monthly)). The `com.apple.developer.persistent-content-capture` entitlement ("for VNC apps", macOS 14.4+) is a **managed capability you must apply for**. Whether Apple grants it to non-VNC remote-desktop apps is unclear ([forum 761641](https://developer.apple.com/forums/thread/761641), [Michael Tsai](https://mjtsai.com/blog/2024/08/08/sequoia-screen-recording-prompts-and-the-persistent-content-capture-entitlement/)). **Plan:** apply for it; until then, the host shows a menu-bar warning before the monthly prompt expires so you re-approve while at home.

## 2. VideoToolbox real-time encoding

Docs: [VTCompressionSession](https://developer.apple.com/documentation/videotoolbox/vtcompressionsession), [WWDC21 10158 *Explore low-latency video encoding with VideoToolbox*](https://developer.apple.com/videos/play/wwdc2021/10158/)

| Setting | Value | Why |
|---|---|---|
| Encoder spec `EnableLowLatencyRateControl` | `true` | Low-latency RC, 1-in-1-out, LTR support. Handle `-12902` by retrying without it. |
| `RequireHardwareAcceleratedVideoEncoder` | `true` | Fail loudly rather than fall back to software. |
| Profile | `HEVC_Main444_AutoLevel` if the client advertises a 4:4:4 decoder, else `HEVC_Main_AutoLevel`, else H.264 High | Negotiated per session |
| `RealTime` | `true` | |
| `AllowFrameReordering` | `false` | No B-frames = no reorder delay |
| `MaxKeyFrameInterval` | very large; `ForceKeyFrame` on demand | IDR only on join or unrecoverable loss |
| LTR (`EnableLTR`, `ForceLTRRefresh`, ack via `AcknowledgedLTRTokens`) | on for UDP paths | Loss recovery without an IDR |
| `AverageBitRate` + `DataRateLimits` | from ABR | |
| Refinement frame | per-frame `kVTEncodeFrameOptionKey_...` QP override or a second session in constant-quality mode | Crisp static text (protocols.md §3) |

- **Constant QP vs bitrate:** VT exposes `Quality` (0–1) and, on newer OSes, min/max QP (`MinAllowedFrameQP`/`MaxAllowedFrameQP`). **Strategy:** bitrate mode for motion, capped by `MaxAllowedFrameQP` so text never degrades past a floor; refinement frames clamp QP low.
- **4:4:4 evidence:** `HEVC_Main444` / `HEVC_Main44410` were offered by the hardware HEVC encoder on an M3 Pro (macOS 27.2) ([aetherdesk #44](https://github.com/stormlantern-dev/aetherdesk/issues/44)). The same project measured **~41 ms (4:2:0) vs ~55 ms (4:4:4)** end-to-end to a PC client, so 4:4:4 encode is slower. **M1 will measure this on your M5.**
- **No AV1 hardware encoder** on Apple silicon (decode only), so AV1 is out.

## 3. Input injection

Docs: [CGEvent](https://developer.apple.com/documentation/coregraphics/cgevent), [CGPreflightPostEventAccess](https://developer.apple.com/documentation/coregraphics/3258226-cgpreflightposteventaccess)

- **Mouse and keyboard:** `CGEvent(mouseEventSource:mouseType:mouseCursorPosition:mouseButton:)`, `CGEvent(keyboardEventSource:virtualKey:keyDown:)`, posted with `.post(tap: .cghidEventTap)`. Use a dedicated `CGEventSource(stateID: .hidSystemState)`. Set click state (`mouseEventClickState`) for double and triple clicks. Use **absolute positions on the virtual display's coordinate space** for direct touch and relative deltas (with client-side acceleration) for trackpad mode.
- **Permission:** "Accessibility" (TCC). `CGPreflightPostEventAccess()` / `CGRequestPostEventAccess()` to check and request. Non-sandboxed, Developer ID only (an App Store Mac app can't post events this way).
- **Scrolling with real momentum:** `CGEvent(scrollWheelEvent2Source:units: .pixel, …)` with `scrollWheelEventIsContinuous = 1` and the **scroll phase / momentum phase fields** (`scrollWheelEventScrollPhase`, `scrollWheelEventMomentumPhase`). Apps then see trackpad-like scrolling (elastic bounce, natural feel), not a clicky mouse wheel. We forward the phone's gesture phases (began/changed/ended) and let **the Mac generate momentum**, or generate it client-side and send momentum-phase events. M2 decides which feels better.
- **Pinch zoom / smart zoom:** no public API for synthesizing magnify gestures. Options: (a) translate to ⌘+ / ⌘- (works in most apps), (b) private gesture CGEvent fields, as used by WebKit's test harness ([WebKit EventSenderProxy](https://webkit.googlesource.com/WebKit/+/0c2ad854b02baf7dcfb76f96705de638b478e115/Tools/WebKitTestRunner/mac/EventSenderProxy.mm)). Default to (a) and keep (b) behind a flag.
- **Mission Control / Spaces / App Exposé:**
  - Public and robust: post the system shortcuts **⌃↑** (Mission Control), **⌃↓** (App windows), **⌃←/⌃→** (switch Space), fn/F11 (Show Desktop). These are user-configurable, so the host reads `com.apple.symbolichotkeys` to find the actual bindings.
  - Fallback: `open -b com.apple.exposelauncher` for Mission Control.
  - Private: synthetic **dock-swipe gesture events** (undocumented CGEvent fields 55/110/132, used by [iss](https://worker-github.zxx930427.workers.dev/joshuarli/iss), [InstantSpaceSwitcher](https://hublens.pages.dev/en/jurplel-InstantSpaceSwitcher/), [When the Stars Align](https://jorvik-software.pages.dev/notes/2026/04/10/when-the-stars-align)). These give true 1:1 swipe tracking but can break between macOS releases. **Behind a flag, off by default.**
- **Local input while remote:** if the curtain should also block local keyboard and trackpad, a `CGEventTap` at the session level can swallow local HID events. That needs **Input Monitoring** permission. Optional.

## 4. Virtual displays

- **There is no public API** to create a virtual display. Every product (BetterDisplay, DeskPad, open-source tools) uses the **private `CGVirtualDisplay` family** (four undocumented Obj-C classes in CoreGraphics) ([vdisplay](https://github.com/pacifistazero/vdisplay), [opendisplay](https://github.com/peetzweg/opendisplay), [osplay go/no-go PR](https://github.com/akinalpfdn/osplay/pull/2)). Community reports say it still works on macOS 26 and 27. Apple's own HP Screen Sharing creates virtual displays (up to 4K), so the facility is alive and maintained.
- **Why we need it:** (1) **crisp text**: a display whose pixel size equals the phone's panel region means zero resampling (see iphone-duo.md); (2) **instant posture switching**: one virtual display with modes for laptop/flat/closed; (3) **lid closed**: with the lid shut and no external display, there is no active display to capture.
- **Risk:** medium. A macOS update can break it. **Mitigations:** keep the class wrapper tiny and isolated; on failure, fall back to **capturing the built-in display + scaling** (works with the lid open; blurrier); or a **$5–10 HDMI/USB-C dummy display plug** (hardware, no API risk) whose resolution we set via public `CGDisplayMode` APIs.
- **App Store impact:** none for the Mac host (we're Developer ID). It only matters if we ever wanted a Mac App Store host, which input injection already rules out.

## 5. Staying awake, reachable, starting at login

- **Keep awake:** `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep, …)` always while the host is running on AC power (configurable), plus `kIOPMAssertionTypePreventUserIdleDisplaySleep` **only during a session** ([IOPMLib](https://developer.apple.com/documentation/iokit/iopmlib_h)). `IOPMAssertionDeclareUserActivity` to wake the display when a session starts.
- **Lid closed (relevant: the repo is called *Clamshell*):** macOS stays awake lid-closed only with **power + an external display** (Apple's clamshell mode). With **no external display**, it sleeps on lid close regardless of assertions; `caffeinate` doesn't override lid sleep. `sudo pmset -a disablesleep 1` is the known workaround, with **conflicting reports on Apple silicon** (works on 26.3 per one report, not since Ventura per another) ([kanaries](https://docs.kanaries.net/articles/how-to-make-mac-not-sleep), [braindetox](https://braindetox.kr/en/posts/electronic_clam_clamshell_agent_2026.html)). **Plan:** M5 tests (a) a virtual display plus `disablesleep`, (b) a dummy-plug clamshell. Either way, **it must stay on the charger**.
- **Reachable:** the host keeps an outbound session to the server with keepalives every ~15 s (NAT bindings on home routers often expire at 30–60 s for UDP).
- **Launch at login:** `SMAppService.mainApp.register()` (macOS 13+) for the menu-bar UI; `SMAppService.agent(plistName:)` for a helper LaunchAgent that restarts on crash ([SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)).
- **After a reboot:**
  - With **FileVault on**, the Mac stops at the pre-boot unlock screen and no user code runs. **macOS 26+ on Apple silicon can unlock FileVault over SSH** (Remote Login) ([Apple Platform Support](https://support.apple.com/en-ke/guide/platform-support/sup909bba3a2/web), [Jeff Geerling](https://www.jeffgeerling.com/blog/2025/you-can-finally-manage-macs-filevault-remotely-tahoe/); Wi-Fi works as of 26.5). That only helps if something can reach the Mac's SSH: **a home-hosted server box on the LAN can relay to it**, but a Mac-embedded server can't (it's off). That's a point for running the server on a separate always-on device at home.
  - **Login window (after FileVault unlock or with FileVault off):** a `LaunchAgent` with `LimitLoadToSessionType = LoginWindow` can run there, but **pre-login capture with ScreenCaptureKit is broken on Sequoia** for at least one remote-desktop vendor ([forum 768146](https://developer.apple.com/forums/thread/768146)). **Robust fallback:** tunnel the Mac's own Screen Sharing (VNC, `localhost:5900`) through our E2E session and use a minimal RFB view on the phone just for the login screen. **Status: stretch (your Q4: "nice to have").**

## 6. Privacy curtain (blank the physical screen during a session)

| Option | Public API? | Works lid-open? | Notes |
|---|---|---|---|
| **Capture a virtual display; black out the built-in one** | Virtual display is private; blackout is public | ✓ | Mirror nothing to the built-in panel: set brightness to 0 (private `DisplayServices`) **or** cover it with a black `NSWindow` at `CGShieldingWindowLevel()`. The shield is on the *physical* display only, so it never appears in the virtual display we capture. |
| **Shield window + exclude it from capture** (single display) | **✓ public** | ✓ | Full-screen black window on the built-in display, excluded via `SCContentFilter(display:excludingWindows:)`. Simple. Local users can't see the screen, and the capture shows real content. Local input still works unless blocked via an event tap (§3). |
| Switch the console to the login window (Chrome RD style) | Private (CGSession) | ✓ | Chrome RD has a Mac curtain policy ([Google](https://support.google.com/chrome/a/answer/2799701)). Too invasive. |
| Lid closed | — | n/a | Naturally curtained. |

**Recommendation:** the shield window plus capture exclusion as the always-available curtain; with the virtual display active, shield the built-in panel. Both are cheap.

## 7. Permissions summary (first-run checklist)

| Permission | Why | When |
|---|---|---|
| Screen & System Audio Recording | Capture | M1 |
| Accessibility | `CGEvent` posting | M2 |
| Local Network | Bonjour/LAN discovery (macOS 15+ prompts for it) | M1 |
| Input Monitoring | Only if blocking local input during the curtain | M6 (optional) |
| Login item (SMAppService) | Auto-start | M5 |
| Remote Login (SSH), user-enabled | FileVault remote unlock (stretch) | Stretch |
| System Settings → Battery → "Prevent automatic sleeping on power adapter when the display is off" | Stays reachable | Setup guide |
