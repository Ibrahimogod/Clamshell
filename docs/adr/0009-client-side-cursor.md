# ADR-0009: Cursor drawn on the phone; the Mac reconciles

**Status:** Proposed · **Date:** 2026-11-15

## Context
If the cursor is part of the video, every trackpad movement waits for a network round trip, encode and decode before you see it move: 30–150 ms. That is the single biggest "feels remote" signal.

## Decision
- The Mac captures with `showsCursor = false` and streams **cursor shape updates** on the control channel:
  - image (PNG, ≤ 64×64 pt @2×),
  - hotspot,
  - a hash so shapes are cached and sent once,
  - visibility.
  Shapes are read from `NSCursor.currentSystem` plus a cursor-change hook. Hidden or system cursors (I-beam, resize) are covered.
- The phone draws the cursor in its own Metal layer above the video at 120 Hz, moved by **local** trackpad deltas through the acceleration curve (ADR-0013).
- The phone sends **relative deltas plus a sequence number**. The Mac applies them with `CGEvent` mouse-moved events and reports the authoritative position at 60–120 Hz (`seq`, `x`, `y`).
- **Reconciliation:** if the Mac's position for `seq` differs from the phone's prediction by more than 2 pt (a window snapped it, the cursor hit an edge, an app warped it), the phone eases to the Mac's position over 50 ms. Otherwise it ignores the report.
- **Direct touch (flat posture):** absolute positioning. The phone shows the cursor at the finger and sends absolute coordinates; no prediction is needed.

## Consequences
- ➕ The pointer moves on the next phone frame, ≈ 8 ms, regardless of network.
- ➖ Apps that warp or confine the cursor (games, some 3D tools) show brief corrections. That's acceptable for the VS Code/Xcode target.
- ➖ The recorded video lacks a cursor, so the measurement harness draws its own marker.
