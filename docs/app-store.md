# App Store notes (iOS client)

The phone app is meant to stay App Store eligible. Nothing here has been submitted yet.

## Privacy manifest

`ios-client/Resources/PrivacyInfo.xcprivacy` is bundled with the app:

- no tracking, no tracking domains, **no collected data types**: the screen, input, clipboard, files and sound travel
  only between the phone and the user's own Mac, end-to-end encrypted, and no server of ours is involved;
- required-reason APIs: `UserDefaults` (CA92.1, the app's own settings) and system boot time (35F9.1, monotonic clocks
  for frame timing and latency).

In App Store Connect's privacy questions the answer is "Data Not Collected".

## Export compliance

`ITSAppUsesNonExemptEncryption` is **true**: the app implements its own end-to-end protocol (Noise IKpsk2 on CryptoKit:
X25519, ChaCha20-Poly1305, SHA-256), so it isn't covered by the "HTTPS only" exemption. It uses only standard,
published algorithms and no proprietary crypto, which is normally classified as mass-market (ECCN 5D992.c under
License Exception ENC). That usually means answering Apple's questions as "uses standard encryption" and filing the
annual self-classification report with the US BIS. **Check Apple's current questions and the BIS rules before you
submit**; this note isn't legal advice.

## Review notes to give Apple

- The app needs the user's own Mac running Clamshell Host; give the reviewer a short video, since they can't pair.
- Pairing is local-network only (QR + six digits), so the app asks for local network access and the camera.
- No accounts, no sign-in, no purchases.
