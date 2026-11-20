# ADR-0015: Lid-open-on-charger mode: privacy curtain, shield window, power assertions

**Status:** Accepted (built in 1.2.0) · **Date:** 2026-11-15, updated 2026-11-19

## Context
You answered that the MacBook is **always open on the charger**. During a remote session anyone at home could see your screen or touch the keyboard. The Mac must stay awake while it's reachable, without burning the built-in panel 24/7.

## Decision
- **While the host is enabled and on AC:**
  - hold `kIOPMAssertPreventUserIdleSystemSleep`, so the Mac never idle-sleeps;
  - allow the **display** to sleep normally;
  - the host also sets `NSProcessInfo.beginActivity(.idleSystemSleepDisabled, …)`.
- **On battery** (the charger got unplugged): post a notification and keep serving for 30 min or down to 20% battery, then release the assertion.
- **Session start:** hold `kIOPMAssertPreventUserIdleDisplaySleep` for the *virtual* display. The built-in display is covered by the curtain.
- **Privacy curtain (default ON):**
  - a full-screen borderless `NSWindow` at `CGShieldingWindowLevel()` on the built-in display, showing:
    - a calm "In use remotely — Clamshell" screen;
    - the paired device's name;
    - the time the session started;
  - the window is **excluded from capture** with `SCContentFilter(…, excludingWindows: [curtain])`;
  - the built-in display's brightness is dimmed to minimum. Restored after.
- **Local input:** physical keyboard or trackpad activity on the Mac, detected via a `CGEventTap` that ignores events tagged with our source state ID, does the following:
  - the curtain shows "Someone is using this Mac locally — Clamshell paused";
  - the remote input stream is paused, and the phone shows a banner;
  - pressing **Esc three times** on the physical keyboard ends the session.
  This gives anyone at home a clear, safe kill switch, and the remote user knows.
- **Session indicator:**
  - the menu-bar icon turns filled + accent coloured;
  - a notification fires on every session start ("iPhone Duo connected via Work Wi-Fi · WSS");
  - the macOS screen-recording indicator also shows, which can't be avoided and is good.
- **Lock behaviour:** if the Mac is locked (screen saver / lock screen) when you connect, you see the lock screen and unlock it with your Mac password over the stream. Clamshell never stores your Mac password.

## Update, 1.2.0 (2026-11-19): what was built

- The curtain is a black borderless window per **physical** display at `CGShieldingWindowLevel()`,
  `ignoresMouseEvents`, `sharingType = .none`, joining all Spaces. It is created transparent, left out of the
  stream with `SCStream.updateContentFilter(excludingWindows:)`, and only then made opaque; if the exclusion
  fails, it stays down so the phone never streams black. Panels are rebuilt when screens change.
- Modes: **away only** (default), **always**, **never**; the phone can override per session (`PrivacyRequest`,
  0x0029). The phone sees the state in `HostState` tags 10–11.
- Local input: instead of only pausing remote input, an **optional block** (`CGEventTap` at the head of the
  session) drops local keys, clicks and scrolls while the curtain is up. Esc ×3 is counted before the drop,
  so it always ends the session; system-defined keys (power, media) pass. Without the block, local input
  still pauses the phone as before.
- When the phone drops, the curtain lingers 20 s for a reconnect; any local key or click lifts it.
- Not built: dimming the built-in panel. RustDesk dims by setting the display gamma to zero; that is a
  possible later alternative to panels, at the cost of a black frame if the process dies mid-session.
- Unlocking: the phone's unlock sheet types the password as key presses (`PasswordTyping`); the lock screen
  is captured and takes injected keys, so no privileged helper is needed.

## Consequences
- ➕ Your screen is private at home, a local person can always take over, and the Mac stays reachable.
- ➖ A permanently open lid on the charger means battery health is handled by macOS's Optimised Charging. Recommend the 80% charge limit (macOS 26+ setting).
- ➖ The screen-recording permission re-prompts monthly on macOS 15+. The host warns you 3 days before expiry. We apply for the `persistent-content-capture` entitlement (Apple approval needed; low odds for a personal app).
