# ADR-0015: Lid-open-on-charger mode: privacy curtain, shield window, power assertions

**Status:** Proposed · **Date:** 2026-11-15

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

## Consequences
- ➕ Your screen is private at home, a local person can always take over, and the Mac stays reachable.
- ➖ A permanently open lid on the charger means battery health is handled by macOS's Optimised Charging. Recommend the 80% charge limit (macOS 26+ setting).
- ➖ The screen-recording permission re-prompts monthly on macOS 15+. The host warns you 3 days before expiry. We apply for the `persistent-content-capture` entitlement (Apple approval needed; low odds for a personal app).
