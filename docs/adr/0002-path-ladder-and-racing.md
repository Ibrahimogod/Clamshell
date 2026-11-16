# ADR-0002: Path ladder, raced in parallel; WSS-on-443 via the system proxy as last resort

**Status:** Proposed · **Date:** 2026-11-15

## Context
The phone moves between home Wi-Fi, cellular and a hostile work Wi-Fi. The best path differs on each, and a wrong guess costs seconds. Target: **connected from work in < 3 s**, and **recovery in < 2 s after the network comes back**.

## Decision
The client keeps a ranked list of **paths** and races them happy-eyeballs style. The first path to complete an authenticated Noise exchange carries traffic. Better paths keep probing in the background and take over when they succeed.

| Rank | Path | Transport | When it wins |
|---|---|---|---|
| P1 | **LAN direct** | UDP to the Mac's Bonjour-discovered LAN address (`_clamshell._udp`) | At home |
| P2 | **Home direct UDP** | UDP to `homeIP:randomUDPPort` | Cellular; permissive networks |
| P3 | **Home direct WSS** | `wss://homeIP:443/` via `URLSessionWebSocketTask` (honours system proxy and PAC) | 443-only work Wi-Fi, HTTP proxy, TLS inspection |
| P4 | **HTTPS stream** (M6, only if P3 is blocked) | Long-lived chunked GET for the downlink + POSTs for the uplink, over the same URLSession | Proxies that strip the WebSocket `Upgrade` |
| P5 | **Relay** (optional, later) | Same UDP/WSS to a VPS running `/server`, which forwards opaque packets | Only if home-direct ever becomes impossible (CGNAT, ISP block) |

### Racing rules
- **On launch or network change** (`NWPathMonitor`), start P1–P3 at once with a 150 ms stagger (P1 at 0 ms, P2 at +150 ms, P3 at +300 ms). Cancel the losers when a winner authenticates, but keep one cheap UDP probe running every 5 s while on P3 and promote to UDP when it answers.
- **Path memory:** remember per network (keyed by SSID hash, or "cellular") which path won. On a known network, start the remembered winner first with no stagger. On known work Wi-Fi that's P3 straight away, saving ~300 ms.
- **Liveness:** keepalive every 1 s while idle and 5 s while backgrounded. Three missed keepalives (UDP) or a socket error (WSS) re-race immediately while the old path is still being tried. No exponential backoff for the first 10 s after a network change. After that, back off to 5 s.
- **Handover without a gap:** during a switch, both paths may carry packets for ~500 ms. The receiver de-duplicates by counter. Video asks for an LTR-based recovery frame, not a full IDR (ADR-0008).
- **Never split one frame across two paths.**

### WSS details (P3)
- `URLSessionWebSocketTask` because it is the only Apple API that automatically uses the system HTTP proxy, PAC and proxy authentication.
- The path is `/` plus an opaque version prefix, the subprotocol is empty, and the response headers look like a stock web server.
- Binary messages carry our Noise packets 1:1. We disable Nagle (on by default for URLSession) and use HTTP/1.1 upgrade, because HTTP/2 WebSockets (RFC 8441) through proxies are unreliable.
- **TCP head-of-line blocking** is the price. On WSS the frame policy switches to "latest frame wins": if the send buffer holds more than ~1 frame, skip encoding until it drains (ADR-0008).

## Alternatives considered
- **Sequential fallback** (try UDP, time out, then TCP): costs 1–3 s every time on a UDP-blocking network, which breaks the 3 s target.
- **TURN-style relay** as the 443 fallback: unnecessary now that home has a forwarded 443. It would add two Egypt↔EU legs.
- **MPTCP / multipath QUIC:** not exposed in a way that crosses our UDP/WSS split.

## Consequences
- ➕ The best path is always used. Work Wi-Fi connects on P3 in roughly 4 RTT: TCP, TLS 1.3, WS upgrade, Noise IK.
- ➕ Failover is client-driven. The Mac just accepts authenticated packets from wherever they arrive.
- ➖ Battery: parallel probes are short (≤ 2 s) and stop after the winner is found.
- ➖ Corporate DPI may flag long-lived WebSockets. Mitigations are P4 and the generic web camouflage (ADR-0003).

## Your input needed (in M3)
- Use the in-app **Network check** once at work. It reports which of P1–P4 work, the RTT on each, and whether a proxy or TLS inspection is in the way. It makes no changes. It just tells us whether P4 is ever needed.
