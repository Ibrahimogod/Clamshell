# ADR-0016: No pre-login / FileVault access in v1

**Status:** Proposed · **Date:** 2026-11-15

## Context
Login-window access is "nice to have, not essential". The Edge runs inside the Mac app (ADR-0004), which only runs after you log in. ScreenCaptureKit capture of the login window is broken on Sequoia and later. FileVault pre-boot unlock is possible over SSH on macOS 26+, but only if something on the LAN can reach the Mac's SSH while it sits at pre-boot.

## Decision
- **v1:**
  - after a reboot or power cut, Clamshell is unreachable until you log in physically;
  - the Mac app auto-starts at login via `SMAppService.mainApp`;
  - **the lock screen (post-login) is supported**: you can unlock remotely (ADR-0015).
- **Recommended Mac settings** (SETUP.md):
  - "Start up automatically after a power failure" ON;
  - automatic macOS updates set to "download, install manually", so the Mac doesn't reboot itself while you're at work.
- **Later (not scheduled):** with a small always-on home box (ADR-0004 alternative E2), add:
  - SSH relay → FileVault unlock;
  - tunnelled built-in VNC for the login window.
  Same `/server` code.

## Consequences
- ➕ No extra hardware, and nothing exposed before login.
- ➖ A power cut while you're away means no access until you're home. The menu-bar churn log also records reboots, so we can see if this happens.
