# ADR-0017: Debug HUD + local-only metrics; minimal logs; no content ever

**Status:** Proposed · **Date:** 2026-11-15

## Decision
- **HUD (phone):**
  - toggled by a 3-finger long-press on the Mac view or a button in the fold toolbar;
  - updated at 4 Hz;
  - fields:
    - **path** (LAN-UDP / Direct-UDP / WSS-443 / HTTPS-stream / Relay), plus a proxy-detected and TLS-inspected flag;
    - **RTT** (EWMA + p95);
    - jitter, loss %;
    - **fps**, three numbers: Mac encoded / phone received / phone presented;
    - **bitrate** (current, target);
    - **codec** (HEVC 4:4:4 / 4:2:0 / H.264) + resolution + "refined" marker;
    - **dropped frames** (network / late / decoder);
    - encode / decode ms;
    - **estimated glass-to-glass**;
    - thermal state, battery draw.
  - Tap the HUD to expand to 10 s sparklines. Long-press copies a JSON snapshot to the clipboard for bug reports.
- **Metrics (local only):** both apps keep a rolling 7-day local SQLite of per-session aggregates (path, durations, p50/p95 RTT, fps, bitrate, reconnects). No network telemetry, no analytics SDKs, no crash-report services. Crash logs only via Apple's own TestFlight / Xcode Organizer, which you control.
- **Mac logs** (`os_log`, subsystem `app.clamshell`, plus a rotated file kept 30 days):
  - session start/stop, device name and key fingerprint (first 8 bytes);
  - path type, source IP (kept 30 days, then hashed), byte counts;
  - pairing events, revocations, failed-auth counters per IP (aggregated);
  - IP-change events.
- **Never logged anywhere:** frames, keystrokes, key codes, clipboard contents, file names sent, window titles.
- **Relay (if ever deployed):** counters only (bytes, sessions, auth failures). No IPs in logs beyond a 24 h abuse window.

## Consequences
- ➕ Enough to debug "why is it slow at work" without any content exposure.
- ➖ No remote crash reporting beyond Apple's. That's acceptable for personal use.
