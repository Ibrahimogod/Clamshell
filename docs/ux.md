# Clamshell UX

Clickable mockups: [mockups/index.html](mockups/index.html). Open it in a browser, use the posture tabs at the top, and toggle light/dark. Related ADRs: [0007](adr/0007-virtual-display-capture.md), [0012](adr/0012-posture-inference.md), [0013](adr/0013-input-model.md).

## 1. Principles
1. **The Mac is the content; Clamshell disappears.** No chrome over the Mac view except the HUD (opt-in) and transient banners.
2. **Exact behaviour, original look.** The deck behaves like a MacBook keyboard and trackpad. Its visual skin is Clamshell's own.
3. **Posture is the mode switch.** Fold the phone, and the layout follows within 150 ms. No menus needed.
4. **Never surprise the Mac.** Mode changes on the Mac (virtual display size) wait for a stable posture (600 ms) and can be locked.
5. **Fast feedback everywhere.** Local cursor, key-down haptics, instant pressed states, a visible path/quality pill.

## 2. Design language: "Shell & Ember"
Original, not derived from Apple hardware or any competitor's "shell".
- **Palette:**

| Token | Light | Dark |
|---|---|---|
| Background ("porcelain" / "ink") | `#F3F0EA` | `#111418` |
| Deck surface | `#E6E0D5` | `#191D24` |
| Key cap | `#FCFBF8`, with a 2 px **lip** (`#D3CABB`) on the bottom edge | `#272C36`, lip `#0B0D10` |
| Text | `#1D2330` | `#ECE8E1` |
| Accent **Ember** | `#E5603B` | `#FF7B55` |
| Link **Tide** (connected / good path) | `#17907F` | `#3CC6B2` |
| Caution | `#C98A12` | `#E7AE3A` |
| Danger | `#C8372D` | `#F0625A` |

  Accent use:
  - **Ember** marks active and latched states: sticky modifiers, the drag lock, the selected posture.
  - **Tide** marks connection health.

- **Shape:**
  - keys are rounded rectangles with an 18% corner radius and a bottom "lip" instead of a shadow;
  - modifier labels sit bottom-left, in a symbol + word pair ("⌘ cmd");
  - the trackpad is a recessed panel with a faint dot grid at 6 mm pitch (a tactile cue for where you are). This is distinct from MacBook trade dress.
- **The Seam:** the fold region in laptop posture holds a thin **Seam bar**. Nothing interactive sits *on* the crease; controls sit just below it:
  - left: path pill (`● WSS · 38 ms`);
  - centre: deck mode switcher (Deck / Split / Pad / Keys);
  - right: HUD, clipboard, ⋯ (disconnect, settings).
- **Type:** Inter (UI) and JetBrains Mono (HUD), with system-ui fallback. No SF Pro in mockups, to avoid trade-dress confusion.
- **Motion:** 120 Hz. Key-down is instant (0 ms), key-up animates 60 ms. Posture transitions use a 220 ms spring.
- **Device frame in mockups:** a neutral rounded outline, not a rendering of Apple hardware.

## 3. Laptop posture (default; partially open, fold horizontal)
- **Top half:** the Mac at 1:1 pixels (939 × 667 pt mode). A banner area slides in from the top edge for states: reconnecting, paused locally, IP changed.
- **Bottom half: the Deck.** Four deck modes, switched from the Seam bar or with a 2-finger swipe on the Seam:

| Mode | Layout | Use |
|---|---|---|
| **Deck** (default) | Exact MacBook ANSI keyboard (≈ 55% height) above a **large trackpad** (≈ 45%), proportioned like a MacBook deck | General use |
| **Split** | Keyboard split into left and right thumb halves along the outer edges, trackpad in the centre | Two-thumb typing while holding the phone |
| **Pad** | Whole deck is trackpad; a single slim row of `esc ⌃ ⌥ ⌘ ⇧` and arrows floats at the top | Reading, mouse-heavy work |
| **Keys** | Whole deck is keyboard with larger keys, F-row always visible | Long typing sessions on a table |

- **F-row:** swipe down on the number row to reveal F1–F12 and media keys (brightness, Mission Control, volume). Swipe up to hide. `fn` + number also works.
- **Sticky modifiers** (setting): one tap latches (ember ring), a double tap locks (filled ember), the next key releases.
- **Key popups:** off by default for an exact feel; on as an option.
- **Haptics:** light on key-down, medium on trackpad click, rigid on force click, soft tick on drag-lock engage.

## 4. Flat posture (fully open)
- The Mac fills the screen (1335 × 939 pt landscape mode).
- **Input toggle** (floating pill, bottom-right, auto-fades):
  - **Direct touch:** tap = click at finger; long-press = right-click; two-finger drag = scroll; pinch = zoom.
  - **Trackpad:** the whole screen acts as a trackpad over the image, with relative pointer movement.
- **Floating mini keyboard:** summoned by a 3-finger tap or the pill. It's a compact, draggable 4-row MacBook layout that can dock to the bottom edge and goes translucent when not touched.
- **Dock:** swipe up from the bottom edge. A peek handle appears, and a release shows the Mac Dock (pointer warp).
- **Menu bar:** swipe down from the top edge, the same way, for the Mac menu bar when it's autohidden.

## 5. Book posture (partially open, fold vertical)
- The Mac's picture stays as in laptop posture (same display mode), across both pages at the top.
- Below it the keyboard splits at the fold: left half (esc–F6, the `` ` `` key to 6, Tab–T, Caps–G, Shift–B, 🌐 ⌃ ⌥ ⌘ space) on the left page, right half (F7–🔒, 7–delete, Y to the backslash key, H–return, N–shift, space ⌘ ⌥ arrows) on the right. Each half keeps MacBook-shaped keys (about 1.35× as wide as tall) at its page's outer edge; within a half, the key next to the fold grows so the rows line up.
- The trackpad strip (optional) sits between the halves, one pad per page beside the fold (20–45% of each page by its size setting), so the picture keeps its height. It still reads a finger on each page as one gesture.
- Key size, whether keyboard and strip show, and the strip's size are in Layout › Keyboard & trackpad (shared with laptop posture).
- Earlier design, replaced in 1.0.1: the Mac on the left page in a 667 × 939 pt portrait mode, the deck on the right.

## 6. Closed: the cover screen (5.4″)
- **Glance view** (default when you close it during a session; the session pauses after 30 s):
  - Mac name, online dot (Tide = reachable, grey = unknown, Danger = unreachable), last-known path and RTT;
  - "Last session 12 min ago · 1 h 40 m";
  - battery and charging state of the Mac, and the IP-change counter.
- **Quick actions** (2×3 grid of large tiles):
  - **Lock Mac** (⌃⌘Q);
  - **Sleep display**;
  - **Wake** (re-asserts display wake);
  - **Disconnect all**;
  - **Send clipboard** (when enabled);
  - **Phone session**: a full portrait session on the cover screen (699 × 1017 pt), with the trackpad as an overlay.
- **Unfold to resume:** the session continues on the inner display within 1 s, with no re-auth if within 5 min.

## 7. Other screens
- **Pairing (phone):**
  1. Welcome.
  2. Camera scanner with a frame guide.
  3. "Check the code on your Mac" with the large 6-digit SAS.
  4. Done.
- **Pairing (Mac):**
  1. Menu → Pair new iPhone → admin auth.
  2. QR + countdown (120 s).
  3. When a phone connects: "Which code does your iPhone show?" with 3 choices (prevents click-through).
  4. Device named.
- **Network check (phone):** runs P1–P4 in sequence and shows, for each one:
  - pass/fail;
  - RTT;
  - detected proxy;
  - TLS inspected (yes/no, issuer name);
  - a one-line verdict ("UDP blocked; WSS works through proxy `proxy.corp:8080`; expect ~40 ms").
  A "Copy report" button produces text for you to paste to me.
- **Settings:**
  - pointer speed + **acceleration curve editor** (draggable curve with presets);
  - tap-to-click, drag style (3-finger drag / drag lock);
  - natural scrolling;
  - sticky modifiers, key popups, layout (ANSI/ISO/Arabic labels);
  - ⌘-Tab remap;
  - haptics intensity;
  - quality preference (Sharpest text / Balanced / Smoothest);
  - **clipboard sync** (off by default);
  - Touch ID unlock;
  - HUD;
  - lock layout per posture;
  - "more space" display size.
- **Mac menu bar:**
  - status line ("Idle · reachable at 41.x.x.x" / "In use · iPhone Duo · WSS 38 ms");
  - Pair new iPhone…;
  - Devices ▸ (rename, revoke);
  - Disconnect all;
  - Pause remote access;
  - IP history ▸;
  - Curtain on/off;
  - Settings…;
  - Quit.

## 8. States and banners (top of Mac view, auto-dismiss where safe)

| State | Banner | Action |
|---|---|---|
| Connecting | "Connecting… trying home Wi-Fi, direct, HTTPS" | — |
| Reconnecting | "Network changed, reconnecting" (spinner, last frame dimmed 20%) | — |
| Switched path | "Now on WSS · 41 ms" (2 s toast) | — |
| Paused locally | "Someone is using your Mac" | Wait / Disconnect |
| IP changed | "Your Mac's address may have changed" | Enter IP / Scan at home |
| Incompatible | "Update Clamshell on your Mac (needs 2.x)" | — |
| Screen Recording expiring | "Mac permission renews in 3 days" | — |

## 9. Accessibility
- Dynamic Type in all Clamshell UI. The Mac view itself is pixels, so we offer Zoom: pinch in direct-touch mode, or ⌃-scroll forwarded to macOS's own zoom.
- VoiceOver labels on all deck keys and controls. Reduce Motion disables springs.
- Colour is never the only signal: the path pill has text and an icon.
