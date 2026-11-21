# Wire protocol v1.0 (as built in M1)

The source of truth is `shared/Sources/ClamshellWire`. The golden byte fixtures in
`shared/Tests/ClamshellWireTests/Fixtures/v1.0/*.hex` pin every message below: changing a layout breaks
`FixtureTests`. Versioning rules are in ADR-0011, the crypto in ADR-0001 and docs/security.md.

## Outer packet (one UDP datagram, ≤ 1200 bytes)

| First byte | Packet | Notes |
|---|---|---|
| `0x01` | Noise IKpsk2 handshake initiation | phone → Mac |
| `0x02` | handshake response | Mac → phone |
| `0x03` | cookie reply | reserved for M3 (DoS cookies) |
| `0x04` | transport | `0x04 \| receiverIndex u32 \| counter u64 \| ChaChaPoly(inner messages)`. 29 bytes of overhead, 2048-packet replay window |

The VPS (from M3) only ever sees these outer packets. Everything below is inside the AEAD.

## Inner messages

One transport packet carries one or more back-to-back messages:

```
channel u8 | type u16 | flags u8 | length LEB128 | body[length]
```

Channels: `0` control (reliable from M3), `1` video (latest wins), `2` input, `3` clipboard, `4` files,
`5` audio. A receiver skips messages with an unknown type. A body is a list of
`tag LEB128 | length LEB128 | value` TLVs, so a newer peer can add tags without breaking an older one. The
exception is `VideoFragment`, which has a fixed layout because it's on the hot path.

| Type | Message | Ch. | Direction | Body |
|---|---|---|---|---|
| `0x0001` | Hello | ctl | both | 1 protoMajor · 2 protoMinor · 3 appVersion · 4 build · 5 capabilities (bits) · 6 displayMode (repeated) · 7 maxFps · 8 deviceName |
| `0x0002` | Incompatible | ctl | both | 1 requiredMajor · 2 peerMajor · 3 upgrade hint |
| `0x0003` | Ping | ctl | phone → Mac | 1 id · 2 t1 (phone ns). id 0 is the transport keepalive (t1 on another clock): ignore its Pong |
| `0x0004` | Pong | ctl | Mac → phone | 1 id · 2 t1 · 3 t2 (Mac receive ns) · 4 t3 (Mac send ns), used for NTP-style `ClockSync` |
| `0x0005` | Goodbye | ctl | both | 1 reason |
| `0x0010` | KeyframeRequest | ctl | phone → Mac | 1 reason (sessionStart, frameLost, decoderError, formatChanged) · 2 lastGoodFrameId |
| `0x0020` | HostStats | ctl | Mac → phone, 2 Hz | 1 encodeMicros · 2 framesSent · 3 keyframes · 4 refinements · 5 bytesSent · 6 encoderDrops · 7 skippedWhileBusy (all optional, HUD only) |
| `0x0101` | VideoFormat | video | Mac → phone | 1 generation · 2 codec · 3 width px · 4 height px · 5 chroma · 6 fullRange · 7 parameter set (repeated: VPS, SPS, PPS) |
| `0x0102` | VideoFragment | video | Mac → phone | fixed: `frameId u32 \| index u16 \| count u16 \| flags u8 \| formatGeneration u16 \| captureTimeNs u64 \| payload` (19-byte header, ≤ 1145-byte payload) |

Capability bits (never reused): 0 hevc444Decode · 1 ltr · 2 fecRS · 3 audioOpus · 4 clipboardV1 ·
5 filesV1 · 6 hdr · 7 hevc420Decode · 8 refinementFrames · 9 benchBarcode.

Video frame flags: bit 0 keyframe · bit 1 refinement · bit 2 long-term reference.

A keyframe is always preceded by a `VideoFormat`, in the same burst. The client builds a new decoder
only when the format generation changes on a keyframe, and otherwise asks for a keyframe (ADR-0008).

## Protocol 1.2 (M2: input, cursor, clipboard)

Additive: a 1.1 peer ignores the new types and never sees them unless it advertised the capability.
New capability bits: 12 `inputV1` · 13 `clientCursor` (bit 4 `clipboardV1` is now used). `HostState` gains
tag 5 `inputAllowed` (whether the Mac may post events; sent only to an `inputV1` phone).

| Type | Message | Ch. | Direction | Body |
|---|---|---|---|---|
| `0x0030` | CursorShape | ctl (bulk) | Mac → phone | 1 shapeId (FNV-1a of the image) · 2 PNG at 2× · 3 hotX · 4 hotY · 5 width · 6 height (points × 16) |
| `0x0040` | BulkChunk | ctl | both | 1 transferId · 2 index · 3 count · 4 data (≤ 1000 bytes). Carries one inner message ≤ 4 MiB |
| `0x0041` | BulkAck | ctl | both | 1 transferId · 2 received bitmap. Unacked chunks resend every 150 ms, 20 tries |
| `0x0201` | KeyEvent | input | phone → Mac | 1 seq · 2 page (7 keyboard, 0x0C consumer) · 3 usage · 4 down · 5 modifiers |
| `0x0202` | PointerMove | input | phone → Mac | 1 seq · 2 dx · 3 dy (points × 16, zigzag) · 4/5 absolute x/y (fraction × 65535) |
| `0x0203` | PointerButton | input | phone → Mac | 1 seq · 2 button (0 left, 1 right, 2 middle) · 3 down · 4 modifiers |
| `0x0204` | Scroll | input | phone → Mac | 1 seq · 2 dx · 3 dy (points × 16) · 4 phase (none, began, changed, ended, cancelled) · 5/6 release velocity pt/s · 7 modifiers |
| `0x0205` | Gesture | input | phone → Mac | 1 seq · 2 kind (1 spaceLeft … 14 lookUp) |
| `0x0206` | InputState | input | phone → Mac | 1 seq · 2 modifiers · 3 held key usages · 4 buttons. Every 250 ms while anything is held |
| `0x0210` | CursorPosition | input | Mac → phone | 1 appliedSeq · 2 x · 3 y (points × 16 from the display's top-left) · 4 visible · 5 shapeId |
| `0x0301` | ClipboardOffer | clipboard (bulk) | both | 1 changeCount · 2 item (repeated: 1 UTI · 2 data) |

Input rules (ADR-0013):
- one sequence counter per session; each packet carries the new message plus the previous two flagged
  `redundant`, and the tail is resent 30 ms after the last event. The Mac applies each seq once (window 1024);
- modifiers: bits 0–7 = HID modifier byte (0xE0–0xE7), bit 8 capsLock, bit 9 fn (usage 0x03). Every key,
  button and scroll carries the full bitmap; the Mac reconciles to the newest one, so a lost packet can't
  leave ⌘ stuck. The Mac releases everything after 2 s without input;
- autorepeat, click counting and scroll momentum happen on the Mac, with the Mac's own settings.

## Protocol 1.3 (M3: pairing, internet paths, home endpoint)

**Paths (ADR-0002).** The same outer packets travel over three paths: P1 LAN UDP (Bonjour), P2 home UDP
(the router's forwarded port, default 443) and P3 TLS + WebSocket on TCP 443, one binary WebSocket message
per packet. The outer TLS is camouflage only (ADR-0003): the phone accepts any certificate, and Noise inside
authenticates the Mac. The phone starts the paths 150 ms apart and sends on all of them until one answers;
the best-ranked path that answers is used. Every 2 s it copies one packet to better-ranked paths so a better
one can take over (straight away when a better path comes up, or joins mid-session once the phone sees the
Mac on its Wi-Fi), and a path silent for 400 ms while sending is dropped and the race starts again. The Mac
answers on whichever path the newest authentic packet came from (roaming), except that it stays on a
local-network address while it has heard the phone there in the last 0.5 s. The WSS listener drops packets
while more than 384 KB is queued to a socket, so video never builds a TCP backlog; sockets silent 30 s close.

**Pairing, outer type `0x05` (ADR-0014).** `0x05 | step | 00 00 | pairingId(4) | body`, LAN source
addresses only (private, link-local, loopback), and only while the Mac's pairing window is open (120 s).

| Step | Direction | Body |
|---|---|---|
| 1 | phone → Mac | `Noise_XXpsk3_25519_ChaChaPoly_SHA256` message 1 (`e`), empty payload |
| 2 | Mac → phone | message 2 (`e, ee, s, es`), payload: Mac name |
| 3 | phone → Mac | message 3 (`s, se, psk`), payload: phone name |
| 4 | Mac → phone | ChaChaPoly(k₂, n=0, ad=header) of `accepted(1) · udpPort(2) · tcpPort(2) · len(1) publicHost` |

Prologue `clamshell.pair.v1`. The PSK is `HKDF-SHA256(secret, info "clamshell-pair-psk")`, where `secret` is
the 80-bit one-time value in the QR code (`CLAMPAIR1:` + base64url of `v1 · S_mac(32) · secret(10) · port(2)
· name · addresses`) or typed as 16 base32 characters. SAS = first 4 bytes of `HKDF(h, info "clamshell-sas")`
as a big-endian integer mod 10⁶; `psk_session = HKDF(h, salt "clamshell-psk-session")`, used as the IKpsk2
PSK of every later session. The phone repeats its current step every 400 ms; the Mac answers repeats from a
cache. Three failed message 3s (wrong secret) close the window. Step 4 is sent only after the person at the
Mac confirms that the digits match.

**New message.**

| Type | Message | Ch. | Direction | Body |
|---|---|---|---|---|
| `0x0022` | HomeEndpoint | ctl | Mac → phone | 1 host (public IP or DNS name) · 2 udpPort · 3 tcpPort (0 = listener off) · 4 observedAt (unix s) · 5 seq |

Sent at session start and when the Mac learns a new public address; the phone keeps the highest `seq`.
It arrives inside the Mac's authenticated session, so it needs no signature of its own.

**Network check.** The phone sends a real handshake initiation on one path and waits for an authentic
response, without confirming the session: the Mac never starts streaming and forgets the half-open session
after 10 s.

## Protocol 1.4 (M4: posture display modes)

| Type | Message | Ch. | Direction | Body |
|---|---|---|---|---|
| `0x0023` | DisplayModeRequest | ctl | phone → Mac | 1 DisplayMode (varints: widthPoints · heightPoints · scale · refreshHz) |

The phone sends it when its posture has held for 600 ms (ADR-0012), only to a 1.4 Mac. The Mac checks the
size (320–2560 pt, scale 1–3, 30–120 Hz), rebuilds the virtual display, capture and encoder, and carries the
frame id (+16) and the format generation (+1) on from the old stream. The phone keeps its pipeline: the next
keyframe brings the new parameter sets, and the larger frame ids keep the old stream's late packets from
looking newer. `Hello.displayModes` now lists the four posture modes with the current posture's first.

## Protocol 1.5 (M5: files and sound)

| Type | Message | Ch. | Direction | Body |
|---|---|---|---|---|
| `0x0302` | FileOffer | ctl, via bulk | phone → Mac | 1 name (UTF-8) · 2 sha256 (32 bytes) · 3 data |
| `0x0401` | AudioPacket | audio | Mac → phone | 1 seq · 2 captureNs (Mac clock) · 3 one Opus packet (1–1500 bytes) |

**FileOffer** is sent through the bulk path (`BulkChunk`/`BulkAck`), whose sender keeps 512 chunks in
flight and resends after 150 ms; a transfer is at most 32 MiB. The Mac advertises `filesV1`, but saves a
file only when its "Accept files from the phone" setting is on. It checks the hash, keeps only the name's
last path component without control, bidi or ":" characters or leading dots, and never overwrites.

**AudioPacket** is 20 ms (960 frames) of 48 kHz stereo Opus. Both sides advertise `audioOpus`. It is never
retransmitted. The phone plays a packet only if its seq is newer than the last one (a step back of more than
25 is a new stream), and drops packets while more than 120 ms is already queued, so sound never adds
latency or falls behind the picture.

## Protocol 1.6 (keyboard layouts)

| Type | Message | Ch. | Direction | Body |
|---|---|---|---|---|
| `0x0024` | KeyboardLayout | ctl, via bulk | Mac → phone | 1 input source id · 2 localized name · 3 language (BCP 47) · 4 repeated key: TLV {1 HID usage · 2 label · 3 shifted label} (≤ 256 keys, labels ≤ 16 bytes) |

**KeyboardLayout** is sent at session start and whenever the Mac's selected input source changes. The phone
only uses it to label its keys; keys still travel as HID positions, so the Mac's own layout types them.

**KeyEvent on page `0xFF43`** (Clamshell vendor page): usage `0x01` down asks the Mac to select its next
enabled keyboard input source (🌐 tapped alone). It is never a key, and the Mac ignores every other usage on
that page and on any page other than 7 (keyboard) and 12 (consumer). The phone sends it only to a 1.6 Mac (one
that has sent a KeyboardLayout). Until another key goes down, a held 🌐 is not sent as fn, so a tap never
reaches the Mac as a bare fn press.

## Protocol 1.7 (reconnects)

| Hello tag | Field | Type | Meaning |
|---|---|---|---|
| 9 | connectionId | uint64, optional | Random, non-zero, fresh for each connection the phone opens; the same across its rekeys |

The Mac keys sessions by the phone's static key. When a new handshake from a phone it already has a session
with completes, it compares the two Hellos' connectionId:

- **Same id: a rekey.** The old session keeps decrypting until it expires, and the stream, input sequence and
  cursor state carry on.
- **Different id (or only one side has one): a new connection.** The old session is dropped and the Mac
  starts afresh as for a first connect: a new stream, a new input sequence and the current pointer shape.

Before 1.7 the Mac took every second handshake from a phone for a rekey. After the phone dropped off Wi-Fi
and connected again before the old session timed out, the Mac kept the old session's input state: the new
connection's input (sequence numbers starting at 0 again) was dropped as already seen and the pointer shape
was never re-sent, so the pointer vanished and input did nothing until the old session expired. Two pre-1.7
peers (no id on either side) keep the old behaviour.

## Protocol 1.8 (Mac → phone files, microphone, one window, frame-rate cap, app expiry)

| Type | Message | Ch. | Direction | Body |
|---|---|---|---|---|
| `0x0025` | FrameRateRequest | ctl | phone → Mac | 1 maxFps (0 = no cap) |
| `0x0026` | WindowListRequest | ctl | phone → Mac | empty |
| `0x0027` | WindowList | ctl, via bulk | Mac → phone | 1 repeated window: TLV {1 window id (non-zero) · 2 app · 3 title · 4 width · 5 height (points)} (≤ 64, front to back) |
| `0x0028` | SourceRequest | ctl | phone → Mac | 1 windowId (0 = the whole screen) · 2 fit (bool) |
| `0x0302` | FileOffer | ctl, via bulk | **also** Mac → phone | as in 1.5 |
| `0x0401` | AudioPacket | audio | **also** phone → Mac | as in 1.5, but 48 kHz **mono** voice |

| Hello tag | Field | Type | Meaning |
|---|---|---|---|
| 10 | appExpires | uint64, optional | When the phone app's signature runs out (Unix seconds); absent for builds that don't expire |

| HostState tag | Field | Type | Meaning |
|---|---|---|---|
| 7 | micReady | bool, optional | The Clamshell Microphone driver is installed, so the phone's mic can be heard |
| 8 | window | string, optional | The title of the window being streamed; absent for the whole screen |
| 9 | fps | uint | The rate the Mac streams at now (0 = unknown) |

New capability bits: 14 `filesToPhone` · 15 `micOpus` · 16 `windowStreaming` · 17 `frameRateCap`. Each new
message is sent only to a peer that advertised the matching bit, so 1.7 peers never see them.

**FrameRateRequest** comes from the phone's battery and heat saver. The Mac streams at the display mode's
rate under that cap, but never below 15 fps (`FrameRateRequest.effective`), and rebuilds the stream when the
cap changes. Without a request the cap is the Hello's `maxFps` when it is below 120 (1.8 phones only).

**SourceRequest** with a window id makes the Mac capture that window alone
(`SCContentFilter(desktopIndependentWindow:)`). Pointer input and the cursor are mapped into the window's
frame, which the Mac re-reads every 250 ms. A move follows at once, a resize rebuilds the stream, and when
the window closes the Mac goes back to the whole screen. With `fit`, the Mac first resizes the window
(Accessibility) so that it shows at 1:1 on the phone's picture, inside its display's visible frame. If the
window can't be captured, the Mac keeps streaming the whole screen.

**FileOffer, Mac → phone:** the phone checks the hash and saves the file under the same name rules as the Mac,
in `Documents/From Mac` (Files › On My iPhone › Clamshell › From Mac), never overwriting. The size limit is
still 32 MiB.

**AudioPacket, phone → Mac:** 20 ms packets of the phone's microphone, with iOS voice processing (echo
cancellation) on. Only while the phone's mic button is on, and only to a Mac that advertised `micOpus`. The
Mac plays them into the Clamshell Microphone driver (a loopback Core Audio device), under the same rules as
1.5: newer seq only, at most 120 ms queued.

## Protocol 1.9 (files and folders of any size, privacy screen, unlock)

| Type | Message | Ch. | Direction | Body |
|---|---|---|---|---|
| `0x0029` | PrivacyRequest | ctl | phone → Mac | 1 curtain (bool, optional) · 2 blockLocalInput (bool, optional); an absent field leaves that setting as it is |
| `0x0303` | FileBegin | ctl | either way | 1 transferId (non-zero) · 2 batchId · 3 path ("/" separated, ≤ 32 parts, ≤ 1024 bytes) · 4 size · 5 sha256 (32 bytes) · 6 modified (Unix s, optional) · 7 index · 8 count |
| `0x0304` | FileAccept | ctl | receiver → sender | 1 transferId · 2 status (0 accepted, 1 refused, 2 noSpace, 3 badName, 4 alreadySaved; absent = 0) · 3 offset (absent = 0) |
| `0x0305` | FileSegment | files, via bulk | sender → receiver | 1 transferId · 2 offset · 3 data (1 … 65 536 bytes) |
| `0x0306` | FileProgress | ctl | receiver → sender | 1 transferId · 2 confirmed (bytes written in order) · 3 state (0 receiving, 1 checking, 2 saved, 3 damaged, 4 writeFailed; absent = 0) · 4 savedName (optional) |
| `0x0307` | FileCancel | ctl | either way | 1 transferId (0 = the whole batch) · 2 batchId (optional) |

| HostState tag | Field | Type | Meaning |
|---|---|---|---|
| 10 | curtain | bool, optional | The privacy screen covers the Mac's own displays |
| 11 | localInputBlocked | bool, optional | The Mac's own keyboard and trackpad are turned off |

New capability bits: 18 `filesV2` · 19 `curtain`. A side sends FileBegin only to a peer with `filesV2` (and
falls back to the 1.5 FileOffer, ≤ 32 MiB, otherwise), and the phone sends PrivacyRequest only to a Mac with
`curtain`.

**Files.** One file at a time. The sender announces it with FileBegin; the receiver answers FileAccept with
the offset to start from, which is the size of a partial copy it kept from an earlier try (same sha256 and
size), or 0. Segments of 64 KiB follow from that offset, each one bulk transfer, at most 8 in flight past the
receiver's last `confirmed`. The receiver writes them in order (out-of-order segments wait in memory, within
the window) and sends a FileProgress for each. With every byte in, it hashes the file off the main thread
(`checking`), then reports `saved` with the name it used, or `damaged`. A damaged file is sent once more from
0, then fails.

- **Resuming:** the partial copy lives in `<folder>/.clamshell-partial/<sha256>-<size>.part`, with its
  confirmed length saved every 4 MiB or 1 s. A sender repeats FileBegin after 5 s without an answer or 10 s
  without progress, and on reconnecting to the same peer; the receiver answers a repeat with where it is now
  (or `alreadySaved`). After 6 repeats without an answer the file fails. Partials older than 7 days are
  deleted.
- **Names:** the receiver turns `path` into safe components (`FileBegin.safeComponents`: no "..", ".", empty,
  hidden or separator-bearing parts) and never overwrites. The top folder of a batch is mapped once, so a
  folder that already exists gets "Album 2" for the whole batch.
- **Space:** a file is refused with `noSpace` unless the receiver has its size plus 256 MiB free.
- The Mac accepts files only with **Accept files from the phone** on (otherwise `refused`), into ~/Downloads.
  The phone always accepts, into `Documents/From Mac`.

**Privacy screen.** The Mac covers its physical displays during a session according to its menu setting (off,
away only, always). A PrivacyRequest overrides that for the session, and lasts until a different phone
connects. `blockLocalInput` applies only while the curtain is up. Esc ×3 at the Mac ends the session either
way. The phone shows the state from HostState tags 10–11.

**Unlocking** needs no message: the phone's unlock sheet sends the password as ordinary `KeyEvent`s (key
positions from the Mac's `KeyboardLayout`, ADR-0013), then Return.
