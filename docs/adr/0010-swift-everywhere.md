# ADR-0010: Swift 6 everywhere; one `/shared` package; the Linux relay ships later

**Status:** Proposed · **Date:** 2026-11-15

## Context
The protocol framing, Noise state machine, TLV schema, congestion controller and input mapping must behave identically on the phone, the Mac and, optionally, a relay. Your engineering rules call for Swift 6 strict concurrency and no force unwraps in networking or crypto paths.

## Decision
- **Languages:** Swift 6 (strict concurrency, `-warnings-as-errors`) for `/ios-client`, `/mac-host`, `/shared`, `/server` and `/tools`. Metal Shading Language for shaders.
- **`/shared` = `ClamshellKit`**, a SwiftPM package with these targets:
  - `Wire`: TLV codec and message versions;
  - `Session`: the Noise IKpsk2 + transport state machine, with crypto behind a `CryptoProvider` protocol (CryptoKit on Apple; swift-crypto on Linux, for relay tests only);
  - `Paths`: the path abstraction, racing logic and keepalives;
  - `RateControl`: CC, FEC, pacing;
  - `InputModel`: HID ↔ Mac keycode tables, gesture → event mapping, acceleration curves;
  - `Testing`: fakes, a simulated network, Noise test vectors.

  Every target except the platform glue builds on Linux, so CI can run the protocol tests on a cheap Linux runner.
- **Concurrency:**
  - Actors own the session and path state.
  - Hot paths (capture → encode → send, recv → decode → present) run on dedicated serial executors or plain dispatch queues, wrapped in `@unchecked Sendable` types with documented invariants. Real-time video shouldn't hop actors 4 times per frame.
  - No `Task.sleep`-based timing in hot paths; use `DispatchSourceTimer` or display-link callbacks.
- **No force unwraps or `try!`** in `Wire`, `Session`, `Paths` or the crypto glue. A SwiftLint custom rule enforces this, scoped to those targets.
- **`/server`** (SwiftNIO + Docker Compose) = the optional P5 relay and a test peer. The Mac's Edge reuses the same NIO pipeline code inside the XPC helper (ADR-0004). **It ships in M6, or earlier only if home-direct fails** in M3.
- **Dependencies:** `swift-nio`, `swift-nio-ssl` (Edge TLS; on macOS we could use Network.framework's TLS listener instead, decided in M3), `swift-crypto` (Linux only), `swift-argument-parser` (tools). Anything beyond this list needs an ADR.

## Challenges your assumption
- **The brief's `/server` (Docker Compose) is no longer on the critical path.** With home-direct, the Edge lives in the Mac app. `/server` stays in the repo with tests, but isn't deployed unless needed.

## Alternatives considered
- **Go or Rust relay + Swift clients:** two implementations of the wire format and twice the test surface. The relay is tiny, so Swift on Linux is fine.
- **A Rust core with Swift bindings for everything:** strong for crypto, but it adds an FFI and build complexity for a personal project. CryptoKit is already audited and hardware-backed.

## Consequences
- ➕ One wire implementation and one test suite.
- ➖ Swift-on-Linux tooling is less polished, but it's only needed for the optional relay and CI.

## As built in M1 (2026-11-15)
`/shared` (SwiftPM package `ClamshellKit`) has these targets. Names differ from the plan above where the code taught us something:

| Target | What it holds | Platform |
|---|---|---|
| `ClamshellWire` | TLV/LEB128 codec, envelope, every message (incl. `HostStats` 0x0020), golden fixtures | any |
| `ClamshellSession` | Noise IKpsk2 state machine, transport packets, replay window, dev pairing code | any (CryptoKit) |
| `ClamshellTransport` | UDP client/server on Network.framework, Bonjour `_clamshell._udp`, session drivers | Apple |
| `ClamshellRateControl` | `RefinementScheduler` (damage skip, staged refinement, retry), `LatestSlot` | any |
| `ClamshellCodec` | HEVC NAL/SPS parsing (chroma check), Annex B ↔ length-prefixed | any |
| `ClamshellVideo` | VideoToolbox encoder/decoder wrappers, `PixelConverter`, test patterns | Apple |
| `ClamshellVirtualDisplay` (+ `CVirtualDisplay`) | private `CGVirtualDisplay` wrapper with runtime checks | macOS |
| `ClamshellStream` | `HostVideoPipeline` / `ClientVideoPipeline`: fragmenting, reassembly, never-queue | Apple |
| `ClamshellKeychain` | small Keychain store (this-device-only items; data-protection keychain on macOS) | Apple |
| `ClamshellBench` | barcode patch codec, latency stats, `ClockSync` | any |

`Paths` and `InputModel` arrive in M3 and M2. The SwiftLint no-force-unwrap rule isn't wired up yet. Until it is, a grep for `x!` / `try!` over `ClamshellWire`, `ClamshellSession`, `ClamshellTransport` and `ClamshellStream` comes back empty (checked 2026-11-15). CI is an M6 item.
