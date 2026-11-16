# ADR-0014: LAN-only QR pairing + SAS confirm; Secure Enclave–wrapped keys; Touch ID gate

**Status:** Proposed · **Date:** 2026-11-15

## Context
"QR plus short-code pairing; keys in Keychain/Secure Enclave; the server can't impersonate either side; optional biometric unlock." The iPhone Duo has **Touch ID, not Face ID**.

## Decision

### Pairing (once per device, at home)
1. On the Mac: menu → **Pair new iPhone**. This opens a **pairing window for 120 s** and shows a QR code containing:
   - `v`, the Mac's static X25519 public key `S_mac`;
   - LAN addresses + port;
   - a 128-bit one-time secret `k_pair`;
   - the Mac's display name.
2. The phone scans it, which is only accepted if the phone's current network can reach that LAN address. Both sides run **Noise `XXpsk3`** with `k_pair` as the PSK:
   - each side proves possession of its static key;
   - the Edge accepts pairing handshakes **only from private/link-local source addresses** and **only while the window is open**.
3. Both screens then show a **6-digit SAS** derived from the handshake hash (`HKDF(h, "clamshell-sas") mod 10^6`). You confirm on the **Mac** that the digits match the phone, then click **Pair**. This defeats an attacker who photographed the QR code: they could start a handshake, but their SAS would differ and you'd see two requests.
4. On confirm:
   - the Mac stores `S_phone` + name + created-at on its allow-list;
   - the phone stores `S_mac` + the `HomeEndpoint` record (ADR-0005);
   - **both derive and store a 256-bit `psk_session`** from the pairing handshake, used as the `psk2` in every later IKpsk2 session (ADR-0001).
5. Manual-entry fallback if the camera can't scan: the Mac shows a 16-character code of `k_pair` in groups of four (base32), typed on the phone. There's no low-entropy 6-digit-only mode; that would need a PAKE, and it isn't worth it.
6. **Limits:**
   - 3 failed pairing handshakes close the window;
   - opening a new window requires the Mac user's local admin password (`LAContext` / Authorization Services);
   - at most 8 paired devices.

### Key storage
- **Phone:**
  - The X25519 static private key is generated in software (CryptoKit). The Secure Enclave doesn't do X25519; it only does P-256.
  - That key is **wrapped** (ECIES) by a **Secure Enclave P-256 key** and stored in the Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. It never syncs to iCloud.
  - With **Biometric unlock ON** (default ON), the SE key's access control is `.biometryCurrentSet`. Each app launch, or resume after 5 min in the background, requires Touch ID to unwrap. **Enrolling a new fingerprint invalidates the key**, which forces re-pairing at home. There's no passcode fallback, by design.
  - With Biometric unlock OFF, the access control is `.privateKeyUsage` only, unlocked whenever the phone is.
- **Mac:**
  - Same scheme with a Secure Enclave key, without biometrics, so unattended operation works.
  - `psk_session` per device is stored in the Keychain, `ThisDeviceOnly`.
- The **outer TLS key** (ADR-0003) is low-value, stored in the Keychain, and rotated monthly.

### Revocation
- Mac menu → Devices → **Revoke** removes the key from the allow-list and **kills that device's live session within 1 s**.
- **Disconnect all** ends every live session but keeps the pairings.
- **Pause remote access** stops the Edge listener entirely; ports then return TCP RST.

## Challenges your assumption
- **Face ID → Touch ID.** The Duo has no Face ID. The behaviour is the same.

## Consequences
- ➕ No server is ever involved in pairing, so no server can impersonate either side.
- ➕ A stolen phone without your fingerprint is useless for Clamshell (docs/security.md §4).
- ➖ Re-pairing requires being at home. That's intentional.
