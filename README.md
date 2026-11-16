# Clamshell

Turns an iPhone Duo into a pocket MacBook for your own Mac: the Mac's screen, 1:1 and at 120 Hz, on the Duo's
top half, with a MacBook-exact keyboard and trackpad on the bottom half. Only your own hosting is involved.
The link is end-to-end encrypted (Noise IKpsk2), so a relay can never see the screen, keystrokes or clipboard.

| Folder | What |
|---|---|
| `shared/` | `ClamshellKit` Swift package: wire protocol, Noise session, transport, video pipelines, rate control |
| `mac-host/` | Menu-bar host app (macOS, Developer ID, not sandboxed) |
| `ios-client/` | iPhone app |
| `tools/` | `clamshell-probe`, `clamshell-bench` and `bench/` scripts (harnesses, upload sink) |
| `server/` | Optional relay (empty until M6) |
| `docs/` | Architecture, security, video, UX, milestones, protocol, ADRs |
| `research/` | Background research |

Start with **[docs/SETUP.md](docs/SETUP.md)**. Progress is in [CHANGELOG.md](CHANGELOG.md), and the plan is in
[docs/milestones.md](docs/milestones.md).
