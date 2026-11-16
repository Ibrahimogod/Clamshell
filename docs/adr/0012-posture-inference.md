# ADR-0012: Posture inferred from hinge status + division region + geometry

**Status:** Proposed · **Date:** 2026-11-15

## Context
iOS 27.1 exposes `onHingeChange` / `UIHingeInteraction` (status `.closed` / `.partiallyOpen` / `.fullyOpen`, plus `angle`) and `reservedRegions(kind: .division)`. There is **no posture API**, and Apple's guidance is that the angle is for effects, not layout.

## Decision
- `PostureModel` (`@Observable`, main actor) combines three things:
  - the hinge status;
  - the division region frame from `reservedRegions(kind: .division, options: .includeInactive)`;
  - the scene's bounds and interface orientation.
- From those it derives:
  - `closed` → the cover screen is active (the scene moves to the outer display);
  - `fullyOpen` → **flat**;
  - `partiallyOpen` and the division is **horizontal** (wider than tall) → **laptop**: the top half shows the Mac, the bottom half the deck;
  - `partiallyOpen` and the division is **vertical** → **book**;
  - a fallback when the hinge is unavailable (simulator, other devices): aspect ratio + orientation.
- **Debounce 150 ms** for UI layout and **600 ms** for remote display mode changes (ADR-0007). Hysteresis on the angle only for a cosmetic "lid" shading effect.
- **Layout:** `ArrangementView` with `.arrangementViewStyle(.split)` and `.split.axes(.horizontal)` for laptop, `.vertical` for book. The deck sits on the lower region and nothing interactive is placed in the division (fold) region.
- **Overrides:** a quick toggle pins a posture, for when you prop the phone at an odd angle. The pin is remembered per session.
- **Testing:**
  - unit tests of the pure `infer(hinge:division:bounds:)` function;
  - Xcode 27.1 Device Hub fold simulation for UI tests;
  - an on-device checklist in M4.

## Consequences
- ➕ Uses only public APIs, so it's App Store safe.
- ➖ Heuristic. The override toggle covers edge cases.
