# ADR-0013: MacBook-exact deck; CGEvent injection with real trackpad phases; ⌘-Tab strategy

**Status:** Proposed · **Date:** 2026-11-15

## Context
"The deck must work **exactly** like a MacBook keyboard and trackpad." The bottom half in laptop posture is about **4.37″ × 3.1″** (1878 × 1335 px). A MacBook keyboard row is ~11″ wide, so an exact layout is ≈ 0.4× scale, giving ~7.4 mm key pitch, close to an iPhone landscape keyboard.

## Decision

### Keyboard (soft deck)
- **Layout and behaviour identical to a MacBook ANSI keyboard**, with an ISO/Arabic layout option:
  - same rows and stagger;
  - `fn/🌐 ⌃ ⌥ ⌘ space ⌘ ⌥` bottom row and an inverted-T arrow cluster;
  - Esc on the top-left; Delete, Return and Shift sized as on the MacBook.
  - **The F-row (F1–F12 and media keys) appears when you swipe down on the number row**, and `fn` + number also gives F-keys.
- **Visual skin is original** (docs/ux.md). Same layout, not the same look.
- **Key events:** each key sends HID usage + down/up with a timestamp. The Mac maps it to a virtual keycode (`kVK_*`) and posts `CGEvent(keyboardEventSource:virtualKey:keyDown:)` with explicit modifier flags. Typing therefore respects the Mac's input source: Arabic, US and so on are chosen on the Mac, as on a real keyboard.
- **Modifier state is reconciled on every key packet:** the full modifier bitmap is sent each time, so a lost packet can't leave ⌘ stuck. There's also a 2 s watchdog: modifiers auto-release if no packet arrives.
- **Sticky modifiers** (setting): tap ⌘ once to latch it for the next key, or double-tap to lock. This is shown on the key itself.
- **Autorepeat** is generated on the Mac from down/up timing, using the Mac's own key-repeat settings, not the phone's.
- **Haptics:** a light tick on key down. Optional key popups.

### Hardware keyboard (Bluetooth / Smart Connector, if any)
- Use `GCKeyboard` raw key events where available, plus `UIKeyCommand.wantsPriorityOverSystemBehavior = true` to claim as many system shortcuts as iOS allows.
- **⌘-Tab, ⌘-Space and Globe shortcuts are reserved by iOS** and will likely never reach us. Mappings:
  - **⌥-Tab → ⌘-Tab** (default remap, configurable). The *on-screen* deck's ⌘ + Tab always works, since it's our own UI.
  - **⌃-Space → ⌘-Space** (Spotlight), configurable.
- M4 tests exactly which combinations iOS 27.1 on the Duo lets through, and the remap table defaults follow from that.

### Trackpad (soft deck)
Gestures map to the same macOS outcomes as on a MacBook:

| Gesture | Mac result | How it's sent |
|---|---|---|
| 1-finger move | Pointer | Relative delta → local cursor (ADR-0009) → `CGEvent` mouseMoved |
| Tap | Click (tap-to-click) | leftMouseDown/Up |
| Press / force press | Click / Force click | Pressure from touch `force` if available; otherwise long-press 350 ms = force click (setting) |
| 2-finger tap | Right-click | rightMouseDown/Up |
| 2-finger scroll | Scroll with momentum + elastic bounce | `CGEvent` scroll, **pixel units**, `scrollPhase` began/changed/ended + `momentumPhase` generated on the Mac from the release velocity, so apps see a real trackpad |
| Pinch | Zoom | Smart: send `⌘+` / `⌘−` steps, or real magnify gesture events (private `CGEventType` 29/30) behind a flag |
| 2-finger double-tap | Smart zoom | ⌘-double-tap equivalent (flag) |
| 3-finger swipe left/right | Switch Space | Reads the user's bindings from `com.apple.symbolichotkeys` (default ⌃← / ⌃→) and sends them. Private dock-swipe events behind a flag for 1:1 tracking |
| 3-finger swipe up | Mission Control | ⌃↑ (from symbolic hotkeys) |
| 3-finger swipe down | App Exposé | ⌃↓ |
| 4-finger swipe left/right | App switcher (⌘-Tab overlay) | Hold ⌘, Tab per 80 pt of travel, release ⌘ on lift |
| 3-finger drag (setting) / drag lock | Drag | mouseDown + dragged; with drag lock, a lift keeps it held until the next tap |
| Edge swipe up from the deck's top edge (flat: bottom edge) | Show Dock | Pointer warped to the dock edge, a hold, then restore. Or toggle autohide via ⌥⌘D |

- **Acceleration:** a tunable curve, `v_out = gain · v_in^γ` with a low-speed precision zone. Presets: "MacBook-like", which we fit in M2 by measuring real MacBook curves via `IOHIDEvent` logging, plus "Linear" and "Fast". The curve editor is in settings with a live preview.
- **Palm rejection:** touches starting within 6 pt of the keyboard edge, or larger than a radius threshold, are ignored while typing (as on a MacBook).

### Hardware mouse
`GCMouse` relative deltas if the Duo delivers them. Unverified, so tested in M4. Fallback: `UIPointerInteraction`/hover events if iOS exposes a pointer on the Duo.

### Mac side
- Injection needs **Accessibility** (`CGPreflightPostEventAccess` / `CGRequestPostEventAccess`), checked on launch with a guided fix-it screen.
- All injected events are tagged with a source state ID, so the host can ignore its own events and the curtain can detect *local* input (ADR-0015).

## Consequences
- ➕ It behaves like the real thing, including Mac-side repeat and input sources.
- ➖ Small keys in an exact layout. A "Comfort" variant (larger keys, number row on swipe) is offered, but **the default is exact**, as you asked.
- ➖ Private gesture events are behind flags. The default path uses only shortcut equivalents and documented `CGEvent` APIs.
