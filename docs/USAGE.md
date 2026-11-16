# Using Clamshell

Everyday use once both apps are installed and the phone is paired ([SETUP.md](SETUP.md)). Open Clamshell on
the phone and tap your Mac; it remembers the Mac, and with **Touch ID before connecting** on it asks for
Touch ID first.

## The screen

By default the phone shows the Mac's own screen, scaled to fit, with every app and the whole desktop. With
**Show this Mac's own screen** off in the host menu, the Mac adds a screen of its own sized for the phone
instead, and it changes shape as you fold the phone (System Settings › Displays shows it as "Clamshell";
drag windows onto it).

- **The picture is a trackpad.** Drag to move the pointer, tap to click, and use the same gestures as the
  trackpad strip below. With **Layout › Touch clicks on the picture** on, a tap clicks where you touch instead.
- **Pinch** on the picture zooms the phone's view of the Mac to read small text. While zoomed, the view
  follows the Mac's pointer and moving the pinch pans it; pinch back out to see everything. This only changes
  what the phone shows.
- Text that's soft while it moves sharpens a moment after it stops: the Mac sends a refinement pass for still
  screens.

## Postures (iPhone Duo)

The layout follows how you hold the phone, about half a second after you settle. **Layout › Posture** pins
one if you'd rather it didn't change.

| Posture | How you hold it | What you get |
|---|---|---|
| **Laptop** | Half open, fold horizontal | Mac screen on top, keyboard and trackpad below |
| **Book** | Half open, turned sideways | Mac screen across both pages, the keyboard split at the fold with the trackpad between its halves |
| **Flat** | Fully open | One big screen; the keyboard comes up from the bar when you need it |
| **Cover** | Closed | A glance on the cover screen |

On another iPhone, portrait is the laptop layout and landscape is flat.

## The bar

The bar between the screen and the keys shows the connection in use (**lan**, **udp** or **tcp**) and its round
trip. Its buttons, left to right:

- **Layout** (two rectangles): posture, trackpad strip, **Keyboard & trackpad…**, touch clicks, sound, and
  with a hardware keyboard attached, **⌥-Tab and ⌃-Space as ⌘-Tab and ⌘-Space** (iOS keeps ⌘-Tab and ⌘-Space
  for itself).
- **Gauge:** the stats HUD: frames per second, Mbit/s, encode and decode time, drops, latency.
- **Clipboard:** sends the phone's clipboard to the Mac. (iOS asks before an app reads the clipboard, so
  this direction is never automatic.)
- **Share:** sends a file to the Mac's Downloads, up to 32 MB, when the Mac accepts files.
- **Keyboard:** shows or hides the keyboard.
- **✕:** disconnects.

## Keyboard

A MacBook ANSI keyboard with the media row. Keys are sent to the Mac as key positions, so the Mac's own
keyboard layout decides what they type, and the phone's keys show what it will type.

- **🌐 tap** switches the Mac to its next input source; the key shows the current one (**🌐 EN**, **🌐 ع**).
- **🌐 hold** with another key is fn: F-keys on the top row, Home/End/Page Up/Page Down on the arrows,
  forward delete.
- **Caps lock** lights up while on. In book posture the two halves share fn, caps lock and modifiers, so
  holding ⇧ on the left page capitalises a letter on the right one.
- A Bluetooth keyboard and mouse work too while you're connected.

**Arabic and English (or any layouts).** Add them on the Mac in System Settings › Keyboard › Text Input ›
Edit, then use 🌐 on the phone. With Arabic on, the keys show the Arabic letters with the English letter small
in the corner for ⌘ shortcuts (⌘C is still the C key); ⇧ shows the shifted characters. Switching on the Mac
updates the phone's keys too.

## Trackpad

The strip under (or beside) the keyboard, and the picture itself, send real macOS trackpad events.

| Fingers | Gesture | Does |
|---|---|---|
| 1 | move | moves the pointer |
| 1 | tap | click |
| 1 | hold, then move | drag |
| 2 | move | scroll |
| 2 | tap | right-click |
| 2 | pinch | zoom (in apps that support it) |
| 3 | left / right | switch Spaces |
| 3 | up / down | Mission Control / App Exposé |
| 3 | tap | Look Up |
| 4 | left / right | app switcher |
| 4 | up / down | Mission Control / Show Desktop |

In book posture each page has its own pad. A touch that starts on the fold is ignored, so resting a thumb
there does nothing.

## Keyboard & trackpad settings

**Layout › Keyboard & trackpad…** (also on the first screen under **This phone**). Changes apply at once and
are saved on the phone.

- **Show the keyboard** and **Key size**: the height of one row of keys (36–64 pt, default 48). Bigger keys
  leave less room for the trackpad and, in book posture, for the picture.
- **Show the trackpad strip** and **Size**: the picture is a trackpad too, so the strip is optional. In laptop
  posture the size sets the strip's width; in book posture, how much of each page it takes.
- **In laptop posture:** the strip below the keyboard or beside it.
- **Reset to defaults.**

## Clipboard, files and sound

- **Mac → phone clipboard:** turn on **Sync clipboard with the phone** in the host menu, and whatever you copy
  on the Mac is on the phone. Items a password manager marks as concealed never leave the Mac.
- **Phone → Mac clipboard:** the clipboard button in the bar.
- **Files:** turn on **Accept files from the phone (to Downloads)** in the host menu, then use the share
  button in the bar. If macOS asks whether ClamshellHost may use the Downloads folder, click Allow.
- **Sound:** **Play this Mac's sound on the phone** in the host menu (on by default). Mute it on the phone
  with **Layout › Sound**, or for good under **This phone › Play the Mac's sound**.

## The Mac's menu

Click the laptop symbol in the menu bar.

| Item | What it does |
|---|---|
| Allow Screen Recording… / Allow keyboard & mouse control… | Shown until those permissions are granted ([SETUP.md §4](SETUP.md#4-first-run-on-the-mac)) |
| Show this Mac's own screen | On: the phone shows this screen. Off: the phone gets a screen of its own |
| Sync clipboard with the phone | Mac copies go to the phone |
| Play this Mac's sound on the phone | System audio streams to the phone |
| Accept files from the phone (to Downloads) | Lets the phone's share button drop files in ~/Downloads |
| Keep this Mac awake while plugged in | Stops idle sleep on the power adapter only, so the phone can always reach it. The display still sleeps; a connecting phone wakes it |
| Open at login | Starts the host when you log in (System Settings › General › Login Items) |
| Latency barcode / Flash square | Measurement tools, see [DEVELOPMENT.md](DEVELOPMENT.md#bench-harnesses) |
| *Each paired phone* › Revoke | Removes the phone and ends its session at once |
| Pair new iPhone… | Opens the pairing window ([SETUP.md §5](SETUP.md#5-first-run-on-the-phone)) |
| Disconnect all | Ends every session |
| Pause remote access | Refuses all sessions and closes the internet listener until switched off |
| Quit Clamshell Host | |

The menu also shows each connected phone, the path it's using ("· internet" away from home) and the public
address phones use away from home.

## Safety at the Mac

- Using the Mac's own keyboard or trackpad **pauses the phone's input** until the Mac has been left alone for
  3 s; the phone shows "Someone is using the Mac".
- Press **Esc three times quickly** on the Mac to end every session.
- Each time a phone connects, the Mac shows a notification (if you allowed them).
- Only paired phones can connect, pairing only works from your own network, and **Revoke** cuts a phone off
  immediately. See [security.md](security.md) for the full design.
