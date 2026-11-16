import AppKit
import Foundation

let usage = """
clamshell-probe — day-1 feasibility probes (docs/milestones.md, M1)

  encode  [--width 1878] [--height 1334] [--frames 360] [--out path.hevc]
          HEVC hardware profiles, 4:4:4 attempts (SPS chroma check), encode latency and frame sizes.
  crypto  [--iterations 300]
          Seal/open cost per frame on the real fragment → Noise path. Target: < 0.5 ms per 40 KB frame.
  display [--width 1878] [--height 1334] [--hz 120] [--seconds 5] [--request]
          Private CGVirtualDisplay + ScreenCaptureKit at 120 Hz. Needs Screen Recording for the capture part.
  client  --invite CLAMPAIR1:… [--host 127.0.0.1 --port N] [--seconds 10] [--444] [--v10]
          A stand-in phone on this Mac: connects to a running Clamshell Host (Bonjour by default), decodes
          the stream and reports fps, losses, decode time and capture→decoded latency. Sends receiver
          reports (rate control) unless --v10. Through clamshell-netsim it tests remote paths.
"""

let argv = CommandLine.arguments
guard argv.count >= 2 else {
    print(usage)
    exit(64)
}
let args = Args(argv.dropFirst(2))
do {
    switch argv[1] {
    case "encode": try EncodeProbe.run(args)
    case "crypto": try CryptoProbe.run(args)
    case "client":
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            do { try await ClientProbe.run(args) } catch { print("client probe failed: \(error)"); exit(1) }
            sem.signal()
        }
        sem.wait()
    case "display":
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await DisplayProbe.run(args) } catch { print("display probe failed: \(error)"); exit(1) }
            exit(0)
        }
        app.run()
    default:
        print(usage)
        exit(64)
    }
} catch {
    print("probe failed: \(error)")
    exit(1)
}
