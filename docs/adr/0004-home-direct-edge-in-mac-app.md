# ADR-0004: Home-direct; the Edge runs inside the Mac app as a sandboxed helper

**Status:** Proposed · **Date:** 2026-11-15

## Context
Your brief said "no inbound ports, one VPS I control". In Checkpoint 1 you chose instead to host at home with forwarded ports (**TCP 443 + one random UDP port**) and to run the internet-facing part on the Mac itself. Your router's WAN IP equals your public IP, so there is no CGNAT.

## Decision
- **Topology:** phone → (internet) → TP-Link Archer VR400 → port forward → **MacBook Pro**. No VPS in the default deployment.
- **Ports:**
  - TCP 443 → Mac:443. This is the work-network path.
  - UDP *N* → Mac:*N*, where *N* is picked randomly in 20000–59999 at setup. It's the fast path, and the phone stores it at pairing.
  - Nothing else. The Archer's own remote management must be **off**: it would otherwise sit on, or conflict with, those ports.
- **Process split on the Mac**, to contain the internet-facing attack surface:

```
Clamshell.app (menu bar, Developer ID, not sandboxed)
├─ ClamshellHost (main)      TCC: Screen Recording, Accessibility
│    Noise sessions, capture, encode, input injection, keys (Secure Enclave)
└─ ClamshellEdge.xpc         App Sandbox ON, network.server only, NO TCC, NO keys
     TLS 1.3 + HTTP/1.1 + WebSocket parsing, the 404 responder, rate limits,
     per-IP token buckets → forwards opaque Noise packets to main over XPC
```

- UDP goes straight to the main process: there's no parser beyond a fixed 16-byte header and the AEAD check. The complex parsers (TLS/HTTP/WS) live only in the sandboxed helper. A bug there yields a process with no screen, no input, no keys and no files.
- **Binding:** the Edge listens on all interfaces, so it works on the LAN too. Pairing requests are accepted **only** from RFC 1918 / link-local source addresses, and only while a pairing window is open (ADR-0014).
- **Sleep:** while Clamshell is enabled and on AC power, the host holds `kIOPMAssertPreventUserIdleSystemSleep`. With the lid open on the charger the Mac never sleeps, and the display can sleep (ADR-0015).

## Challenges your assumption
1. **"No inbound ports"** → two forwarded ports. You accepted this at Checkpoint 1. The risk is mitigated: the ports answer nothing useful without a paired key (ADR-0003, docs/security.md §5).
2. **"One server I control (VPS)"** → the "server" *is* your Mac. Benefits: lower latency (no Egypt↔EU detour of ~60–120 ms RTT), $0/month, and one less machine to secure. `/server` (Docker Compose relay) still exists in the monorepo as the optional P5 path, but it moves to **M6/optional** (ADR-0010).
3. **Reboot:** nothing listens until you log in after a reboot or power cut. That's accepted, since the login window is nice-to-have (ADR-0016).

## Alternatives considered
- **Edge on a separate home box (Pi/old Mac):** it survives Mac reboots and enables FileVault SSH unlock. You declined it for now, and nothing here precludes adding it later, because `/server` is the same code.
- **VPS relay as default:** it adds latency and a monthly fee, and buys nothing while you have a public IP.
- **Single process, no XPC split:** simpler, but it puts a TLS/HTTP parser reachable from the whole internet into a process that holds Screen Recording and Accessibility rights.

## Consequences
- ➕ Lowest possible latency and $0 recurring cost.
- ➖ **Home upload is the ceiling.** VDSL upload is often 1–5 Mbps. We measure it in M1, and ABR (ADR-0008) is text-first.
- ➖ Depends on WE not blocking inbound 443. **Test in M3 week 1 from cellular.** Fallbacks, in order:
  1. Use another TCP port on cellular while staying on 443 at work. That only works if work allows that port, which is unlikely.
  2. IPv6, if WE assigns it.
  3. P5, the VPS relay.
- ➖ The Mac's power supply and Wi-Fi are now part of availability. Recommend wired Ethernet or 5 GHz Wi-Fi, and a UPS later if power cuts are common.
