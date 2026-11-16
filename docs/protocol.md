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
(the router's forwarded port, default 51820) and P3 TLS + WebSocket on TCP 443, one binary WebSocket message
per packet. The outer TLS is camouflage only (ADR-0003): the phone accepts any certificate, and Noise inside
authenticates the Mac. The phone starts the paths 150 ms apart and sends on all of them until one answers;
the best-ranked path that answers is used. Every 2 s it copies one packet to better-ranked paths so a better
one can take over, and a path silent for 400 ms while sending is dropped and the race starts again. The Mac
answers on whichever path the newest authentic packet came from (roaming). The WSS listener drops packets
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
