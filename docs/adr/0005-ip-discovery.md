# ADR-0005: Learn the home IP on home Wi-Fi + manual fallback; log IP churn

**Status:** Proposed · **Date:** 2026-11-15 · **Contains one open question for you (§ "Decision needed")**

## Context
WE VDSL usually assigns a dynamic public IP. It changes when the router reconnects, or on the ISP's schedule. The phone must find the Mac without ngrok, DDNS services or any other third party (constraint #1).

**A subtlety I glossed over at Checkpoint 1:** the Mac and the phone both sit *behind* the router's NAT. Neither can see the public IP by itself. Something has to tell the Mac what its public address is:
- either the router,
- or something on the internet that reflects the address back.

## Decision
1. **The Mac learns its public IP**, using the first of these that works:
   - **(a) Router readout, self-hosted, no third party.** The Mac asks the Archer VR400 for its WAN address over the LAN admin interface, using your router admin password stored in the Mac Keychain. This is firmware-specific and gets a spike in M3. It must **not** use UPnP, which you want off.
   - **(b) DNS echo, opt-in.** ⚠️ **Third-party flag.** The Mac sends one DNS query to public resolvers that echo your address back, such as OpenDNS `myip.opendns.com` and Cloudflare `whoami.cloudflare`. Two providers are raced and must agree. No account is needed, and they learn nothing beyond the address you're already querying from. This is off by default.
   - **(c) Observed by the phone.** Whenever the phone *does* reach home over the internet, it knows the address it dialed and confirms it to the Mac.
2. **The phone learns it from the Mac.** On every LAN (P1) session the Mac pushes a **signed** `HomeEndpoint{ ipv4, ipv6?, udpPort, tcpPort, observedAt, seq }` record, signed with the Mac's static key, and the phone keeps the newest. During remote sessions the Mac pushes a new record the moment it detects a change.
3. **Manual fallback.** If the stored address stops answering for 30 s, the phone shows "Your Mac's address may have changed", with:
   - a field to type the new IP. It's verified by the Noise handshake, so a typo or a wrong host just fails safely;
   - a "Scan QR at home" button;
   - a hint that the Mac's menu-bar item always shows the current address.
4. **Churn log.** The Mac logs every IP change in a local file, storing past IPs hashed. The menu shows "IP changed 3× in the last 30 days". **After 30 days we decide** whether a seamless option is worth it:
   - **Option A, own domain + DNS API** (~$10/yr). The Mac updates its own A record. ⚠️ The registrar/DNS host is a commodity outside dependency with no access to content.
   - **Option B, tiny VPS beacon** ($4/mo). It stores only the signed `HomeEndpoint` and never relays traffic. Fully self-hosted.
   - **Option C, a static IP from WE.** Usually a paid add-on.

## Decision needed from you
How should the Mac learn its public IP? Your choice decides whether (a) or (b) gets built in M3:
- **Router readout (recommended):** fully self-hosted. You enter your router admin password once in the Mac app, and it stays in the Mac Keychain. There is a risk the VR400 firmware's login scheme is awkward to automate; the M3 spike will tell us.
- **DNS echo:** simpler and robust, but touches two public DNS resolvers (flagged).
- **Both:** router first, DNS echo as a fallback.

## Alternatives considered
- **ngrok / Cloudflare Tunnel / DDNS services:** third-party, so they violate constraint #1. You raised ngrok; it's ruled out.
- **UPnP IGD `GetExternalIPAddress`:** trivial, but requires UPnP enabled on the router. That also lets any LAN device open ports, so it's excluded per your brief.
- **Email or push the new IP to yourself:** needs a mail provider or APNs. Revisit only if churn is high and A/B/C are all rejected.

## Consequences
- ➕ Zero cost in the common case where the IP doesn't change during your workday.
- ➖ An IP change while you're away needs one manual step. The churn log tells us how often that actually happens.
- The record is signed and the handshake is authenticated, so a forged address can't redirect you anywhere useful.
