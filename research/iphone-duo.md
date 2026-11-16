# iPhone Duo platform research

Researched 2026-11-15. The Duo shipped in September 2026 with iOS 27, and the fold APIs arrived in **iOS 27.1 / Xcode 27.1**. Anything I couldn't confirm from Apple or a hands-on source is marked **UNVERIFIED** and has a fallback.

## 1. Hardware

Source: [Apple: iPhone Duo tech specs](https://www.apple.com/iphone-duo/specs/), [Apple Support specs](https://support.apple.com/en-ie/148588)

| | Inner (folding) | Outer (cover) |
|---|---|---|
| Size | 7.6" OLED, nano-texture (matte) | 5.4" OLED |
| Resolution | **1878 × 2670 px**, 430 ppi | **1398 × 2034 px**, 460 ppi |
| Refresh | ProMotion, adaptive **up to 120 Hz** (reviews: 1–120 Hz) | Same |
| Brightness | 1000 typical, 1600 HDR, 3000 outdoor nits | Same |

- **Chip:** A20 Pro (6-core CPU, 7-core GPU). RAM isn't listed.
- **Radios:** Wi-Fi 7 2×2, 5G sub-6 and mmWave (Apple C2 modem), Bluetooth 6.
- **Video playback:** HEVC, H.264, **AV1**. Apple doesn't list whether the HW decoder supports **HEVC 4:4:4 (RExt)**: **UNVERIFIED, the #1 technical risk** (see RECOMMENDATION.md).
- **Biometrics:** **Touch ID, not Face ID.** Face ID's absence is the most common review complaint ([MacStories roundup](https://www.macstories.net/roundups/iphone-duo-review-roundup-great-hinge-messy-apps-and-everybody-misses-face-id/)). Our "unlock before connect" uses `LAContext` biometrics generically, so it's Touch ID here.
- **Pencil:** Apple Pencil (USB-C) supported, **no hover**.
- **USB-C:** USB 3 at 10 Gb/s, DisplayPort out up to 4K.
- **Dimensions:** open 164.6 × 117.8 × 5.2 mm, closed 84.1 × 117.8 × 11.3 mm, 254 g. It folds like a book: the hinge runs along the 117.8 mm edge.

### What that means for screen geometry (derived, verify on device)

The panel is 2670 × 1878 px when held book-style (hinge vertical) and 1878 × 2670 px when rotated (hinge horizontal).

| Posture | Usable area for the Mac | Pixels (approx.) | Notes |
|---|---|---|---|
| **Laptop** (rotated, partially open, hinge horizontal) | Top half | **~1878 × 1335** (aspect ~1.41) | Physically ~4.4" × 3.1". At HiDPI 2×, that's a **939 × 667-point** Mac desktop. |
| **Flat** (fully open, landscape) | Whole inner panel | **2670 × 1878** | Division region is inactive (width 0). |
| **Book** (partially open, hinge vertical) | Left or right half, or both | ~1335 × 1878 each | Less useful for a Mac. Could be "Mac left, trackpad right". |
| **Closed** | Outer display | **1398 × 2034** portrait / 2034 × 1398 landscape | A full phone. Not just a glance screen; a full session is possible. |

The point size assumes a 3× scale (1878/3 = 626 pt wide). **UNVERIFIED.** Read `UIScreen`/scene geometry at runtime; never hard-code it.

**Text-legibility maths.** The laptop top half is about 4.4" wide. Showing a Mac desktop of N points across it:

| Virtual desktop width | Mac 13-pt text height on the glass | Verdict |
|---|---|---|
| 1878 pt (1×, 1:1 pixels) | ~0.77 mm | Unreadable |
| **939 pt (2× HiDPI, 1:1 pixels)** | **~1.5 mm** | Readable at arm's length, **pixel-perfect** |
| 626 pt (3×) | ~2.3 mm | Comfortable, but the desktop is very cramped |

Conclusion: the crisp-text requirement means **a virtual display whose pixel size exactly equals the region of the panel we draw into**, so there is zero resampling. Downscaling the MacBook's own 3024 × 1964 panel to 1878 px wide (0.62×) is what makes competitors blurry.

## 2. Public APIs for fold, posture and the hinge

Primary sources: Apple Tech Talks [*Leverage multiple displays and scenes on iPhone Duo*](https://developer.apple.com/videos/play/tech-talks/111464/) and [*Strike a pose with adaptive layouts on iPhone Duo*](https://developer.apple.com/videos/play/tech-talks/111463/); [Apple Newsroom, Oct 2026](https://www.apple.com/newsroom/2026/10/developers-bring-incredible-new-app-experiences-to-iphone-duo/). Secondary: [Apple Developer Forums group summary](https://developer.apple.com/forums/thread/847644), [slekens.dev: six foldable APIs](https://slekens.dev/en/blog/iphone-duo-xcode-27-1-six-foldable-apis/).

| Need | API | Notes |
|---|---|---|
| Hinge state and angle | SwiftUI `.onHingeChange { old, new in }` with `new.hinge?.status` ∈ `.closed / .partiallyOpen / .fullyOpen`, `hinge.angle: Angle`. UIKit `UIHingeInteraction` (adds `.unknown`; angle in radians). | `hinge == nil` means no hinge. Apple: use it **for interactions and effects, not layout**. Update rate and precision are "system policy, not guaranteed". |
| The fold as a layout region | SwiftUI `GeometryProxy.reservedRegions(kind: .division, options:, layoutDirectionBehavior:)`. UIKit `UIView.reservedRegions(kind:options:)` returning `UIView.ReservedRegion` (`frame`, `margins`, `kind`, `identifier`, `isActive`). | `.division` = the fold, active only when folded; **width 0 when flat**. `.occlusion` = front camera. `.includeInactive` lets you plan ahead. |
| Split across the fold | SwiftUI `ArrangementView { primary } secondary: { … }` with `.arrangementViewStyle(.split / .overlay / .automatic)` and `.split.axes(.horizontal)`. UIKit `UIArrangementViewController` with `setViewController(_:for:)` and `updateArrangement(_:animated:)`. | Default split is horizontal when wider than tall, vertical when taller. Don't nest in a `ScrollView`/`List`. |
| A "posture" enum | **Does not exist.** The forum summary is explicit: "No single pose API. Infer pose from hinge status, orientation, and size class." | See the fallback below. |
| Window size | **No API to request a scene size.** `UIWindowScene` only reports geometry changes. | Fine: we're always full screen. |
| Size classes | Outer: compact width in portrait. Inner: regular/regular. | Folding is a **trait change, not a scene teardown**. The process and **our network connection survive folding**. |
| Bars | `toolbarVerticalEdge` (SwiftUI) / `verticalBarEdge` (UIKit) | System bars can go vertical. We use custom chrome, so we place it ourselves using reserved regions. |
| Outer display while the inner is in use | `sceneAccessory` / `UISceneAccessory` (system decides). `CameraCaptureAccessory` is camera-only. | **No general "draw on the cover while open" API** for us. The cover "lid" glance is only possible while closed, or via a Live Activity / widget. |
| Multiple windows | New scenes can be created **only on the inner display**. | Not needed for v1. |
| Compatibility mode | iOS 26 SDK apps get letterboxed; **the iOS 27.1 SDK is required for edge-to-edge**. | Deployment target: **iOS 27.1**. |
| Testing | Xcode 27.1 **Device Hub** simulates open/close/fold/rotate. | Lets us build UX before touching the device. |

### Posture inference (our fallback design)

```
hinge == nil                                   -> nonFoldable (iPad/iPhone)
hinge.status == .closed  (or scene on outer)   -> closed
hinge.status == .fullyOpen                     -> flat
hinge.status == .partiallyOpen:
    division region frame is wider than tall   -> laptop   (hinge horizontal)
    division region frame is taller than wide  -> book     (hinge vertical)
fallback when reservedRegions is unavailable:  -> compare scene bounds aspect and
                                                  interface orientation
```

Debounce with hysteresis (about 150 ms) so a hinge wobble near a threshold doesn't make the layout flap. The hinge **angle** drives only effects (for example, fading the deck in as the screen opens), never layout.

## 3. Apple's own conventions on the Duo

- **Notes in laptop pose:** the software keyboard takes the **bottom half** of the display ([Tom's Guide review](https://www.tomsguide.com/phones/iphones/apple-iphone-duo-review)). That's our default deck layout.
- **Book pose:** bending like a book **splits the on-screen keyboard** ([Gizmodo](https://gizmodo.com/iphone-duo-review-2000827502)). Reviews differ on whether it's comfortable.
- **Typing in landscape** felt "like a stretch" to some reviewers ([AppleInsider roundup](https://appleinsider.com/articles/26/10/21/iphone-duo-review-roundup-mostly-positive-opinions-unfold)). That argues for a laptop-pose deck with **real key sizes** rather than a full-width stretched keyboard, plus a split mode.
- **Tabletop:** content viewed at a distance goes in the top region, interactive controls in the bottom region (Apple's own guidance in the "Strike a pose" talk).
- **Hinge** holds partial angles very well ("the best foldable at just being partially open", MKBHD via MacStories).

## 4. Hardware keyboard, mouse, trackpad, Pencil

- **Hardware keyboards** work (standard iOS). Text input and the keyboard session **persist across hinge changes**.
- **Mouse and trackpad: no native pointer on the Duo.** A Wired reviewer found a keyboard plus trackpad **only worked after enabling AssistiveTouch** and called for iPad-style pointer support ([MacStories roundup](https://www.macstories.net/roundups/iphone-duo-review-roundup-great-hinge-messy-apps-and-everybody-misses-face-id/)).
  - **What this means for us (UNVERIFIED, test on device in M4):** `GCMouse` (GameController framework) might still deliver raw HID deltas to a foreground app even without a system cursor. That's what we need anyway, since we draw our own cursor. If it doesn't, the fallback is AssistiveTouch plus `UIHoverGestureRecognizer`/pointer events.
- **System shortcuts:** iOS reserves **⌘-Tab** (and typically ⌘-Space and Globe shortcuts). Jump and Screens both document that they can't pass it through ([Screens help](https://help.edovia.com/en/screens-5/features/permute-cmd-ctrl-alt-tab), [Jump support](https://support.jumpdesktop.com/hc/en-us/community/posts/360073755232/comments/360013146372)). `UIKeyCommand.wantsPriorityOverSystemBehavior` exists, but there are reports that it doesn't help for ⌘ combos ([forum](https://developer.apple.com/forums/thread/757077)).
  - Plan: (1) capture keys with `pressesBegan/Ended` (`UIKey.keyCode` HID usages), map HID to Mac virtual keycodes; (2) test `GCKeyboard` for raw ⌘ state; (3) ship remaps (⌥-Tab to ⌘-Tab, Globe to fn) plus an on-deck ⌘-Tab key.
- **Pencil:** supported, without hover. Optional later (precise pointing).

## 5. Low-latency video decode and display

- **ProMotion above 60 Hz on iPhone** needs the `CADisableMinimumFrameDurationOnPhone = YES` Info.plist key, then `CADisplayLink.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)` ([Apple: Optimizing ProMotion refresh rates](https://developer.apple.com/documentation/quartzcore/optimizing-promotion-refresh-rates-for-iphone-13-pro-and-ipad-pro)). The Duo forum summary confirms `CADisplayLink`/`TimelineView` work "as on any other display".
- **Decode:** `VTDecompressionSession` (hardware) → `CVPixelBuffer` (IOSurface-backed) → Metal texture via `CVMetalTextureCache` → draw in a `CAMetalLayer`. Set `kVTDecompressionPropertyKey_RealTime`. One frame in flight; **if a newer frame is decoded before vsync, the older one is dropped** (never queue).
- **Alternative:** `AVSampleBufferDisplayLayer` with `kCMSampleAttachmentKey_DisplayImmediately`. Simpler and power-efficient, but it gives up control of the zoom lens, nearest-neighbour 1:1 sampling and present timing. Keep it as a fallback path.
- **1:1 sampling:** when the virtual display matches the panel region, draw with **nearest/point sampling and integer pixel alignment**. Any fractional offset or linear filter blurs text.
- **Thermals and battery:** reviewers report a single-point hot spot under load and "barely good enough" battery. Hardware decode at 120 Hz is cheap, but we'll profile in M6 and drop to 60 Hz on battery saver or thermal state `.serious`.

## 6. Open questions only the device can answer (M1/M4 test list)

1. Does the A20 Pro hardware-decode **HEVC Main 4:4:4**? Test: `VTIsHardwareDecodeSupported`, plus decoding a 4:4:4 test stream in a probe build.
2. Exact point size and scale of the inner display and the frame of the `.division` region (hinge height in points).
3. `GCMouse`/`GCKeyboard` behaviour on the Duo without AssistiveTouch.
4. Whether `CADisplayLink` actually sustains 120 Hz while the hinge is partially open (some foldables limit rates during posture changes).
