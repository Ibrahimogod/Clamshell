# ADR-0011: Versioned TLV binary protocol with capability negotiation

**Status:** Proposed · **Date:** 2026-11-15

## Context
Rule: "every protocol message is versioned; old clients fail gracefully". The phone (TestFlight) and the Mac (Developer ID) update independently.

## Decision
- **Two layers of versioning:**
  1. **Outer packet:** `type` byte, reserving `0xF0–0xFF`. A new major packet format gets a new type value, and old peers drop unknown types silently. This keeps the stealth property.
  2. **Inner messages,** inside the encrypted payload: `channel(1) | msgType(2) | flags(1) | len(varint) | TLVs…`.
- **Handshake payload, encrypted inside Noise msg1/msg2:** `Hello{ protoMajor, protoMinor, appVersion, build, capabilities: bitset + TLV list }`. Capabilities include:
  - `hevc444Decode`, `ltr`, `fec.rs`, `audio.opus`, `clipboard.v1`, `files.v1`;
  - `displayModes[]`, `maxFps`, `hdr`.
- **Rules:**
  - **Same major:** the session proceeds. Each side uses `min(minor)` semantics and the intersection of capabilities.
  - **Major mismatch:** the Mac finishes the handshake (so the error is authenticated) and sends `Incompatible{ requiredMajor, upgradeHint }`. The phone shows "Update Clamshell on your Mac" or "…on your iPhone" with the version numbers, never a hang or a cryptic error.
  - **TLV evolution:** each TLV has `tag(varint) | len(varint) | value`. Unknown tags are skipped. Tags are never reused. Tags marked *critical* (high bit set) cause a clean `UnsupportedCritical` error instead of silent misbehaviour.
  - **Enums:** an unknown value maps to `.unknown(raw)` and never crashes.
- **Schema source:** one Swift file per message in `Wire/Messages/`, with golden-byte fixture tests. Each released version's fixtures are frozen in `shared/Tests/Fixtures/vX.Y/`, and CI decodes every old fixture with the new code.

## Alternatives considered
- **Protobuf / FlatBuffers:** fine, but they add codegen and a dependency. Our message set is small (~30 types).
- **JSON on the control channel:** readable, but needs a second codec and has a larger attack surface in the parser.

## Consequences
- ➕ Explicit, testable compatibility, and failures are graceful.
- ➖ Hand-written codecs. They're mitigated with fuzzing (`swift-fuzz`/libFuzzer on Linux CI) of every decoder in M6.
