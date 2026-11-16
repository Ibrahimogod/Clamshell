import Foundation
import Network
import Synchronization

let usage = """
clamshell-bench — measurement tools (docs/video.md §2)

  upload --to host:port [--seconds 10]
      Measures home upload, which bounds every remote frame (ADR-0008 remote budget), against your own sink:
      run `python3 tools/bench/upload_sink.py --port 9443` on the VPS (or any machine off your home
      network), then `clamshell-bench upload --to <vps>:9443` on the Mac. The sink prints its own figure.
  upload --apple
      Opt-in only: macOS `networkQuality -d -c`, which talks to Apple's measurement servers (a third
      party; no Clamshell data is sent). Useful as a cross-check, never needed.
  text-refine [--width 1878] [--height 1334] [--bitrate 25] [--target 45]
      Harness D: scroll, stop, then time how long until static text reaches its final sharpness
      (encode → decode on this Mac with the real pipelines). Exit criterion: refined within 150 ms.
  harness-b <video.mov> [--fps 240]
      Glass-to-glass latency from a high-speed phone video of the Mac + phone side by side
      (tools/bench/harness_b.py; needs ffmpeg).
  impair <profile> | impair off
      Prints (does not run) the dnctl/pfctl commands that shape this Mac's traffic for fallback tests.
      Profiles: hotel (60 ms, 2% loss, 8 Mbit), lte (45 ms ±15, 0.5% loss, 20 Mbit), tcp-only (drop all UDP).
      Harness C proper (automated, with the relay) lands in M2.
"""

let argv = CommandLine.arguments
guard argv.count >= 2 else { print(usage); exit(64) }

func option(_ name: String) -> String? {
    guard let i = argv.firstIndex(of: "--\(name)"), i + 1 < argv.count else { return nil }
    return argv[i + 1]
}

func run(_ launchPath: String, _ arguments: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = arguments
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.standardError
    do { try p.run() } catch { return (127, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// Pushes zeros over TCP for `seconds` and reports the rate the network accepted.
func tcpUpload(host: String, port: UInt16, seconds: Double) async -> Double? {
    guard let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
    let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
    let queue = DispatchQueue(label: "bench.upload")
    let sent = Mutex<(bytes: Int, done: Bool)>((0, false))
    let chunk = Data(count: 256 * 1024)
    let ready: Bool = await withCheckedContinuation { cont in
        let once = Mutex(false)
        conn.stateUpdateHandler = { state in
            let resume: Bool? = switch state {
            case .ready: true
            case .failed, .cancelled: false
            default: nil
            }
            guard let resume else { return }
            if once.withLock({ let was = $0; $0 = true; return !was }) { cont.resume(returning: resume) }
        }
        conn.start(queue: queue)
    }
    guard ready else { print("could not connect to \(host):\(port)"); return nil }
    @Sendable func pump() {
        conn.send(content: chunk, completion: .contentProcessed { error in
            let stop = sent.withLock { s -> Bool in
                if error == nil { s.bytes += chunk.count }
                return s.done || error != nil
            }
            if !stop { pump() }
        })
    }
    let start = ContinuousClock.now
    // Warm-up second (TCP slow start) is excluded from the figure.
    pump()
    try? await Task.sleep(for: .seconds(1))
    let warm = sent.withLock { $0.bytes }
    try? await Task.sleep(for: .seconds(seconds))
    let total = sent.withLock { s in s.done = true; return s.bytes }
    conn.cancel()
    let elapsed = ContinuousClock.now - start - .seconds(1)
    let secs = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    return Double(total - warm) * 8 / secs / 1e6
}

switch argv[1] {
case "upload":
    if let to = option("to") {
        let parts = to.split(separator: ":")
        guard parts.count == 2, let port = UInt16(parts[1]) else { print("--to expects host:port"); exit(64) }
        let seconds = option("seconds").flatMap(Double.init) ?? 10
        print("pushing to \(parts[0]):\(port) for \(seconds) s (+1 s warm-up)…")
        if let mbps = await tcpUpload(host: String(parts[0]), port: port, seconds: seconds) {
            print(String(format: "upload (sender-side, TCP): %.1f Mbit/s — compare with the sink's own figure", mbps))
        } else { exit(1) }
    } else if argv.contains("--apple") {
        print("running networkQuality (upload only; Apple's servers)…")
        let (status, out) = run("/usr/bin/networkQuality", ["-d", "-c"])
        guard status == 0, let json = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any] else {
            print("networkQuality failed (\(status)):\n\(out)")
            exit(1)
        }
        let ul = (json["ul_throughput"] as? Double).map { $0 / 1e6 }
        let rpm = json["ul_responsiveness"] as? Double ?? json["responsiveness"] as? Double
        let iface = json["interface_name"] as? String ?? "?"
        print(String(format: "upload: %.1f Mbit/s · responsiveness under load: %@ RPM · interface: %@",
                     ul ?? 0, rpm.map { String(Int($0)) } ?? "n/a", iface))
        print("budget hint (ADR-0008): remote video ≈ 60% of upload → \(String(format: "%.1f", (ul ?? 0) * 0.6)) Mbit/s")
    } else {
        print("upload needs --to host:port (your own sink) or the opt-in --apple; see usage")
        exit(64)
    }
case "text-refine":
    TextRefine.run(width: option("width").flatMap(Int.init) ?? 1878, height: option("height").flatMap(Int.init) ?? 1334,
                   bitrateMbps: option("bitrate").flatMap(Int.init) ?? 25,
                   target: option("target").flatMap(Double.init) ?? 45)
case "harness-b":
    guard argv.count >= 3 else { print(usage); exit(64) }
    let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("bench/harness_b.py").path
    var a = [script, argv[2]]
    if let fps = option("fps") { a += ["--fps", fps] }
    let (status, out) = run("/usr/bin/env", ["python3"] + a)
    print(out, terminator: "")
    exit(status)
case "impair":
    let profile = argv.count >= 3 ? argv[2] : ""
    let shaping: [String: String] = [
        "hotel": "bw 8Mbit/s delay 60 plr 0.02",
        "lte": "bw 20Mbit/s delay 45 plr 0.005",
    ]
    // The stock /etc/pf.conf evaluates anchor "com.apple/*" (filter and dummynet), so rules loaded there apply
    // without editing pf.conf, and flushing that one anchor undoes them.
    print("# Run these yourself (they change this Mac's packet filter; sudo required). Undo with: clamshell-bench impair off")
    switch profile {
    case "off":
        print("sudo pfctl -a com.apple/clamshell -F all\nsudo dnctl -q flush")
    case "tcp-only":
        print("echo 'block drop out quick proto udp from any to any port != 53' | sudo pfctl -a com.apple/clamshell -f -")
        print("sudo pfctl -E")
    case let p where shaping[p] != nil:
        print("sudo dnctl pipe 1 config \(shaping[p] ?? "")")
        print("echo 'dummynet out quick proto { udp tcp } from any to any pipe 1' | sudo pfctl -a com.apple/clamshell -f -")
        print("sudo pfctl -E")
    default:
        print(usage); exit(64)
    }
default:
    print(usage)
    exit(64)
}
