import ClamshellBench
import CoreVideo
import Foundation

struct ProbeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

func fourCC(_ v: OSType) -> String {
    let bytes = [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    return String(bytes: bytes.map { (32...126).contains($0) ? $0 : 63 }, encoding: .ascii) ?? "\(v)"
}

func ms(_ d: Duration) -> Double {
    let c = d.components
    return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
}

func fmt(_ x: Double?, _ digits: Int = 2) -> String {
    guard let x else { return "n/a" }
    return String(format: "%.\(digits)f", x)
}

func stats(_ values: [Double]) -> (p50: Double?, p95: Double?, max: Double?) {
    var s = LatencyStats(capacity: max(values.count, 1))
    values.forEach { s.add($0) }
    return (s.p50, s.p95, values.max())
}

/// Simple `--key value` / `--flag` parser.
struct Args {
    private var values: [String: String] = [:]
    private var flags: Set<String> = []

    init(_ argv: ArraySlice<String>) {
        var it = argv.makeIterator()
        var pending: String?
        while let a = it.next() {
            if a.hasPrefix("--") {
                if let p = pending { flags.insert(p) }
                pending = String(a.dropFirst(2))
            } else if let p = pending {
                values[p] = a
                pending = nil
            }
        }
        if let p = pending { flags.insert(p) }
    }

    func string(_ k: String) -> String? { values[k] }
    func int(_ k: String, _ d: Int) -> Int { values[k].flatMap(Int.init) ?? d }
    func double(_ k: String, _ d: Double) -> Double { values[k].flatMap(Double.init) ?? d }
    func flag(_ k: String) -> Bool { flags.contains(k) }
}
