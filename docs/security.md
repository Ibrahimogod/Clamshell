# Clamshell security model

Status: Proposed (Checkpoint 2). Related ADRs: [0001](adr/0001-custom-noise-transport.md), [0003](adr/0003-outer-tls-is-camouflage.md), [0004](adr/0004-home-direct-edge-in-mac-app.md), [0014](adr/0014-pairing-and-keys.md), [0015](adr/0015-curtain-power-lid-open.md), [0017](adr/0017-diagnostics-and-logging.md).

## 1. What we protect

| Asset | Where it lives | Confidentiality | Integrity |
|---|---|---|---|
| Screen frames | Mac → phone | **Critical** | High |
| Keystrokes, pointer, gestures | phone → Mac | **Critical** (passwords!) | **Critical**: injected input = remote code execution |
| Clipboard, sent files | both | Critical | High |
| Audio | Mac → phone | High | Medium |
| Static private keys `s_phone`, `s_mac`; `psk_session` | Keychain, SE-wrapped | **Critical** | Critical |
| Metadata: that a session exists, IPs, timing, byte counts | network, logs | Low–Medium (accepted) | — |

## 2. Parties and trust boundaries

```
 TRUSTED                        UNTRUSTED                                 TRUSTED
 ┌──────────┐   work Wi-Fi /   ┌─────────┐  ┌──────────┐  ┌───────────┐  ┌──────────────┐
 │ iPhone   │── proxy / TLS ──▶│ internet│─▶│ router   │─▶│ Edge.xpc  │─▶│ ClamshellHost│
 │ (Touch ID│   inspection     │         │  │ (fwd)    │  │ (sandbox) │  │ (keys, TCC)  │
 │  + SE)   │                  └─────────┘  └──────────┘  └───────────┘  └──────────────┘
 └──────────┘                       ▲ optional VPS relay (/server) — UNTRUSTED
```

**Rule:** only the two endpoint processes that hold the Noise keys are trusted with content: the iOS app and `ClamshellHost`. The Edge XPC helper, the router, the work network, the internet and any VPS relay are all treated as **active attackers**.

## 3. Cryptographic design (summary)

- **Pairing:** `Noise_XXpsk3_25519_ChaChaPoly_SHA256`.
  - PSK = the 128-bit `k_pair` from the QR code, padded or derived to 256 bits by HKDF.
  - Accepted only from LAN source addresses while a 120 s window is open.
  - A **6-digit SAS** derived from the handshake hash `h` is confirmed by you on the Mac.
  - Output: each side pins the other's static public key and both derive `psk_session = HKDF(h, "clamshell/v1/psk")`.
- **Session:** `Noise_IKpsk2_25519_ChaChaPoly_SHA256`.
  - msg1 (phone → Mac) carries the phone's static key encrypted under `DH(e_i, s_mac)`, plus a TAI64N timestamp.
  - msg2 completes. Transport keys mix all of: `ee`, `es`, `se`, `ss` and `psk_session`.
- **Transport:** ChaCha20-Poly1305 with a 64-bit counter nonce. 2048-packet anti-replay window. Rekey at 120 s, with the old keys kept for 5 s for in-flight packets, then zeroed.
- **No key material ever leaves the two endpoints.** No server takes part in pairing.

## 4. Proof: the server (Edge helper or VPS) cannot decrypt or impersonate

**Claim 1, confidentiality.** Any party that doesn't hold `s_mac` or `s_phone` (the private keys) *and* `psk_session` can't recover any transport plaintext. The only exception is breaking X25519 CDH or ChaCha20-Poly1305 / SHA-256.

*Argument:*
1. In Noise IKpsk2, the transport keys come from `HKDF` chaining over the shared secrets `DH(e_i, s_r)`, `DH(s_i, s_r)`, `DH(e_i, e_r)` and `DH(s_i, e_r)`, plus `psk`. That is the standard Noise key schedule; see the Noise spec §5.2 and the WireGuard formal analyses by Donenfeld & Milner (Tamarin) and Lipp et al. (CryptoVerif).
2. `DH(e_i, e_r)` uses ephemerals generated fresh per handshake inside the endpoints. Computing it from the public `e_i` and `e_r` seen on the wire is exactly CDH on Curve25519.
3. The Edge helper and any relay **never get** `s_mac`, `s_phone`, `e_i`, `e_r` or `psk_session`. Here's why for each:
   - `s_mac` is generated in `ClamshellHost`, wrapped by a Secure Enclave key the helper's sandbox can't reach (a different code-signing identity and Keychain access group), and never serialised over XPC.
   - The XPC interface between helper and host is **one-directional for content**: it carries `Data` blobs that are already encrypted Noise packets, and the host never sends keys or plaintext to the helper. A unit test asserts the XPC protocol has no method taking or returning key material.
   - `psk_session` exists only in the two endpoints' Keychains.
4. So anything the server does see (ciphertexts, `e_i`, `e_r`, encrypted statics, counters) gives it a CDH or AEAD problem, never a key. ∎

**Claim 2, no impersonation.** A server can't make the phone accept it as the Mac, or the Mac accept it as the phone.
- To complete IK as the responder, a party must decrypt msg1's static-key field (needs `s_mac`) and produce msg2 with a valid tag under keys that mix `DH(s_i, e_r)`, `ee` and `psk`. Without `s_mac` the first step fails.
- To act as the initiator, it needs `s_phone` (for `ss`/`se`) **and** `psk_session`.
- Pinned static keys come from LAN pairing, confirmed by SAS. The server isn't on that path, because pairing is LAN-only and rejected on public interfaces.

**Claim 3, no undetected tampering, replay or reordering beyond the window.** Every transport packet is AEAD-tagged with a unique counter nonce. Duplicates or counters below the window are dropped. msg1 replays are rejected by the TAI64N timestamp, which must strictly increase per initiator key, as in WireGuard. A replayed msg1 can at most cost the Mac one DH.

**What a malicious server *can* do:** drop, delay or reorder packets (denial of service), and observe metadata: sizes, timing, IPs and the fact that a session exists. Packet sizes leak activity levels (typing vs video). That's accepted; padding is a future option (see §9).

**Test-backed, not just argued (M3, `shared/Tests/SecurityTests`):**
- *Honest-but-curious relay test:* run a full session through `/server` (or the Edge helper) in-process. Inject known **canary** plaintexts into frames, keystrokes and clipboard. Record every byte the relay sees, and assert that no canary, nor any 8-byte window of it, appears.
- *Active relay test:* the relay flips bits, replays, reorders, truncates and splices packets across sessions. Assert the endpoints reject each one and never deliver altered input.
- *Impersonation test:* a relay holding everything it could observe tries to answer msg1. Assert the phone aborts.
- *Noise conformance:* the official test vectors for every pattern we use.

## 5. Threat model

| # | Threat | Attacker capability | Mitigation | Residual risk |
|---|---|---|---|---|
| T1 | **Stolen / lost phone** | Has the device; may know the passcode | Keys SE-wrapped with `.biometryCurrentSet`. No passcode fallback. New fingerprint enrolment invalidates keys. App requires Touch ID at launch and after 5 min background. Revoke from the Mac menu kills it within 1 s. **"Remote revoke" has no channel while you're away**, so the biometric gate is the defence until you're home. | A thief with your finger (coercion). Accepted. |
| T2 | **Compromised VPS relay** (if deployed) | Full control of relay process and host | §4: sees only ciphertext + metadata; can't impersonate; relay holds no secrets. | DoS, metadata. |
| T3 | **Compromised Edge helper** (internet-facing parser bug) | Code execution inside `ClamshellEdge.xpc` | App Sandbox (network only, no file access beyond its container); no TCC (no screen capture or input injection rights); no keys (§4). It can only forward or drop packets, the same as T2. The host validates every XPC message (size limits, type checks). | A sandbox escape needs a second exploit. |
| T4 | **Hostile work network** | Blocks UDP, forces proxy, **TLS inspection**, DPI, active MITM | Outer TLS is camouflage, and any outer cert is accepted (ADR-0003). Inner Noise authenticates and encrypts, so the proxy sees ciphertext inside WebSocket frames. MITM fails at the Noise handshake. | Metadata: it can see you hold a long-lived WebSocket to a residential IP. It can block us (DoS). **Check your employer's policy.** |
| T5 | **MITM at pairing** | On your home LAN during pairing; may photograph the QR | Pairing only via LAN while the window is open, PSK from the QR, and a **SAS** shown on both screens and confirmed on the Mac. An attacker's handshake would show a different SAS and an extra request. 3 failures close the window. Opening the window needs Mac admin auth. | You confirm a SAS without looking. The UI makes you type or select the digits from 3 choices, not just click OK. |
| T6 | **Replay** | Records traffic, replays later | Transport counters + anti-replay window. msg1 TAI64N monotonic per peer. Session keys rotate every 120 s (old ones erased). | None known. |
| T7 | **MITM on the internet / DNS / IP redirection** | Sends the phone to a fake host | Phone dials an IP, not DNS. The `HomeEndpoint` record is signed by `s_mac`. A fake host can't finish IK (Claim 2). | DoS only. |
| T8 | **Internet scanners / brute force / DoS on home ports** | Unlimited probes | UDP: silent drop unless a valid msg1 from an allow-listed key arrives. Checking a msg1 costs 1 DH, so rate limits apply. TCP: generic 404. WS without a valid msg1 in 2 s is closed. Per-IP token buckets: 10 TLS handshakes/min, 30 msg1/min. **Cookie mode** under load: WireGuard-style MAC1/MAC2. MAC1 = keyed hash of the Mac's public key, so scanners without it are dropped for free. Global cap of 200 msg1/s. | Volumetric DoS on a home line. Nothing stops that. |
| T9 | **Someone at home** sees the Mac screen or types on it during a session | Physical access to the Mac | Curtain + dimmed panel. Local input pauses remote input and shows a banner on the phone. Esc×3 ends the session. Menu-bar indicator and notification on every session start. | They own a logged-in Mac. Out of scope beyond these signals. |
| T10 | **Compromised Mac** | Malware on the Mac | Out of scope. It already sees everything. Clamshell adds no new exposure. | — |
| T11 | **Stolen Mac** | Has the Mac | FileVault (recommended in SETUP). Phone pairing is useless without `s_phone`. Revoke by re-pairing. | — |
| T12 | **Clipboard leakage** | Clipboard contains secrets | Clipboard sync **off by default**. Per-session toggle. Never syncs items marked `org.nspasteboard.ConcealedType` / `TransientType` (password managers). Size cap 10 MB. | When it's on, it's on. |
| T13 | **Malicious input injection** | Forged input packets | Integrity via AEAD (Claim 3). Input accepted only on an authenticated, not-revoked session. | — |
| T14 | **Supply chain** | Malicious dependency | Dependencies limited to Apple frameworks + swift-nio(-ssl), swift-crypto (Linux), argument-parser. Versions pinned in `Package.resolved`. CI checks hashes. | Apple / SwiftNIO compromise. Accepted. |
| T15 | **Quantum "harvest now, decrypt later"** | Records ciphertext today | `psk_session` is mixed into every handshake (IKpsk2), so a future X25519 break alone is not enough. | Only if the PSK is also stolen. |
| T16 | **Downgrade** | Strips capabilities | Hello / capabilities travel inside the encrypted handshake and are bound by the handshake hash. There's no cleartext negotiation. | — |

## 6. Operational controls

- **Mac menu-bar indicator:**
  - idle: outline icon;
  - session: filled accent icon + device name + path;
  - paused: crossed.
- **Notification** on every session start and every new pairing, with device, path and source network type.
- **Disconnect all** ends every session within 1 s. **Revoke device** removes the key and ends its session. **Pause remote access** closes listeners: ports return RST and UDP drops.
- **Optional "Approve each connection"** mode: the Mac shows a prompt that must be accepted locally. That's useful only when someone is home, so it's off by default.
- **Rate limits and lockout:**
  - pairing: 3 failures close the window;
  - handshakes: per-IP buckets (T8);
  - biometric: iOS's own lockout. After 5 Touch ID failures the key is unusable until the passcode is entered and Touch ID succeeds again.
- **Logs:** minimal and local (ADR-0017). Never frames, keys, keystrokes, clipboard or window titles.
- **Updates:** a major protocol mismatch fails closed, with an explanatory screen (ADR-0011).

## 7. Router and home hardening (goes into SETUP.md)

1. Archer VR400: turn **Remote Management OFF** (otherwise it occupies or conflicts with 443). Turn **UPnP OFF**. Change the admin password from the default.
2. Port forward **TCP 443 → Mac:443** and **UDP N → Mac:N**, nothing else. Give the Mac a DHCP reservation.
3. Router firmware: latest from TP-Link.
4. On the Mac: FileVault on. The macOS firewall can stay on; signed apps get their incoming rule.

## 8. Accepted risks (explicitly)

- Metadata visibility to the work network and ISP (T4).
- Volumetric DoS on the home line (T8).
- Coerced biometric (T1).
- Being unreachable after a reboot or power loss (ADR-0016).

## 9. Future hardening (M6 / later)

- Packet-size padding buckets to blunt traffic analysis.
- Fuzzing of all decoders: TLV, WS framing, Noise.
- An optional **second factor at session start**: a 4-digit PIN that the Mac verifies with Argon2id, plus a lockout.
- Third-party review of the Noise integration before any App Store release.

## 10. Implementation status (M6, 2026-11-16)

The table in §5 is the design. This is what the code does today; the gaps are tracked, not forgotten.

| ID | Status |
|---|---|
| T1 | **Partial.** Touch ID (biometry only, no passcode fallback) before a session, at most every 5 min. Keys are in the Keychain with `AfterFirstUnlockThisDeviceOnly`, **not** Secure-Enclave wrapped with `.biometryCurrentSet` yet, so a new fingerprint doesn't invalidate them. Revoke from the Mac menu works. |
| T2 | Not applicable: no relay is deployed (everything runs on the one Mac). |
| T3 | **Open.** The 443 listener runs inside the host process, not a sandboxed `ClamshellEdge.xpc`. Its parsing is Apple's `NWProtocolWebSocket` + TLS; our own code only sees whole frames, which then go through the same fuzzed decoders as UDP. |
| T5, T6, T7, T13, T15, T16 | Implemented as designed (LAN-only pairing with SAS and Mac auth; TAI64N + counters + rekey; dial by IP, IK; AEAD; IKpsk2; Hello inside the handshake). |
| T8 | **Mostly.** MAC1 drops packets without the Mac's public key before any DH. A per-source token bucket (30 initiations/min, burst 30) and a global cap (200/s) run before the DH (`HandshakeLimiter`). **Not yet:** MAC2 cookie mode under load, the 2 s close for a WebSocket with no valid msg1, TLS handshake limits. |
| T9 | **Mostly.** Local keyboard or mouse use on the Mac pauses the phone's input until the Mac has been idle 3 s, and the phone shows a banner (`HostState` tag 6). Esc pressed three times within 1.5 s ends every session. A notification is posted on every session start, and the menu-bar icon shows streaming. **Not yet:** curtain and dimmed panel. |
| T11, T12, T14 | As designed (FileVault advised in SETUP; clipboard off by default, concealed/transient types never synced, 32 MiB bulk cap; Apple frameworks only on iOS/macOS). |

**Fuzzing (M6).** `WireFuzzTests` mutates every golden fixture (bit flips, truncation, splices, random lengths) through the
envelope, every message body and the bulk receiver; `SessionFuzzTests` mutates handshake initiations (with MAC1
recomputed, so the Noise code itself is reached), transport packets and pairing packets. Defaults are 20 000 and 3 000
iterations from a fixed seed; set `CLAMSHELL_FUZZ_ITERATIONS` for longer runs. No crash or wrong acceptance was found. A
change to only the cleartext sender index of an initiation (MAC1 recomputed) is accepted, which is the same as WireGuard:
the index isn't authenticated and can only cause a failed session (DoS), not access.

**Debug only.** The `developmentPSK` shortcut is honoured only in `DEBUG` builds; Release builds need a paired PSK.
