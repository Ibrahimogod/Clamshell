# ADR-0005: Learn the home IP on home Wi-Fi + manual fallback; log IP churn

**Status:** Accepted, amended 2026-11-20 (router readout built; DuckDNS name added; the Mac opens its own port forwards over UPnP, see the two amendments) · **Date:** 2026-11-15

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

## Amendment (2026-11-20): router readout built, DuckDNS name for the phone

**What changed.** IP changes while away were a manual step. You asked for the Mac to notice them and for the
phone to keep working, and picked a free dynamic DNS name over ngrok-style tunnels and the paid options A–C.
You chose deSEC first, but deSEC has closed free dedyn.io names to new accounts since 2024 (abuse), so you
switched to **DuckDNS**. deSEC stays supported for a domain of your own hosted there.

**Built:**
1. **Router readout (choice a).** With the VR400 admin password saved in the Mac's Keychain (Home address…
   window), the Mac signs in to the router's web UI once a minute, reads `WAN_PPP_CONN` / `WAN_IP_CONN`
   (status and external IPv4), and signs out again. The VR400's web UI encrypts and signs every request
   (AES-128-CBC with a per-login key, signed with the router's 512-bit RSA key; worked out from the router's
   own scripts, see `ClamshellHome`).
   - It skips a round while someone is signed in to the router page, because signing in would throw them out.
   - After the router turns the password down once, it stops until a new one is saved: a few wrong tries
     lock the router page for everyone.
   - Without a password it falls back to NAT-PMP every 10 minutes (read only), then to the typed address.
2. **Notification.** Every change of the address shows a macOS notification and goes in the churn log.
3. **DuckDNS name.** ⚠️ **Third-party flag (accepted by you).** DuckDNS (duckdns.org, free, hosted on AWS)
   holds one A record, e.g. `myhome.duckdns.org`, with a 60 s TTL. The Mac updates it on every change and
   once a day, over HTTPS, with the account token kept in the Keychain. DuckDNS learns the home's public
   address and when it changes, nothing else: no traffic goes through it, and a forged record only leads
   to a failed, authenticated handshake. Its API takes the token in the URL query (HTTPS only; the Mac never
   logs the URL). The Mac only ever sets the IPv4 record, so phones never get an IPv6 address the router
   doesn't forward. A name not under duckdns.org is updated through deSEC's dynDNS API instead (own domain).
4. **The phone dials the name.** The Mac gives the phone the name instead of the address (at pairing
   and in `HomeEndpoint`), so after a change the phone finds the Mac again with nothing to do, wherever it is.
   No protocol change: `HomeEndpoint.host` was already a host name or address.

**Precedence of what phones get:** the DuckDNS (or deSEC) name; else a DNS name typed in the pairing window; else the
address the router reported; else the typed address. Telling home sessions from away ones still compares
against the address, not the name.

**Still true:** the Mac must be on the home network to read the router. With the Mac on another network
(a phone hotspot, say), nothing reaches it from outside anyway.

## Amendment 2 (2026-11-20): the Mac opens its own port forwards over UPnP

**What changed.** The first away test failed although the name and the address were right: the hand-made
forwards pointed at the Mac's old LAN address (its private Wi-Fi address had changed, so the DHCP reservation
no longer matched). You asked why the forwards are needed at all with a name, and then chose to have the Mac
open them itself. **This reverses "no UPnP" from the original brief, by your decision.** UPnP was already on
in the VR400.

**Built:** the Mac finds the router's Internet Gateway Device with an SSDP search (sent to the gateway and to
239.255.255.250), then asks its `WANIPConnection` service (or `WANPPPConnection`) for UDP 51820 and TCP 443 →
this Mac, named "Clamshell", with a one-hour lease. It renews every 30 minutes and at once when the Mac's own
LAN address changes, so a forward never outlives the Mac by more than an hour. While remote access is paused,
or with the switch off (Home address… window, UserDefaults `upnpPortMapping`), it removes its own mappings.
A "Clamshell" mapping that points at another address is replaced; anyone else's mapping on the same port is
left alone and reported in the menu. A forward made by hand (Virtual Servers) on the same port wins over the
Mac's on the VR400, and it keeps the old address: tested 2026-11-20, the public address stopped reaching the
Mac until the hand-made forwards were deleted. So it's one or the other.

**Risk you accepted.** With UPnP on, any device or program on the home network can open ports on the router
without a password, Clamshell's included. That was the reason for "UPnP off". The trade is fewer manual steps
and forwards that follow the Mac. To go back: switch it off in Home address…, turn UPnP off in the router
(NAT Forwarding › UPnP) and forward the two ports by hand (SETUP §6).

**Not used:** UPnP's `GetExternalIPAddress`. The router readout and NAT-PMP stay the address source.

