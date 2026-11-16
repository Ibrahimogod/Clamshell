import Darwin
import Dispatch
import Foundation

// clamshell-netsim: a userspace UDP relay that behaves like a network we don't own, so the remote path
// (rate control, pacing, FEC, keyframe recovery, roaming) can be tested on one Mac with no root and no
// packet filter: phone or probe → 127.0.0.1:<listen> → relay → Clamshell Host's UDP port.
//
// Per direction: loss (random or bursty Gilbert-Elliott) → a bottleneck of `rate` with a drop-tail queue
// of `queue` ms (what a cellular scheduler or a small home router does) → one-way delay + jitter, without
// reordering. Optional outages model a Wi-Fi ↔ cellular handover.

let usage = """
clamshell-netsim --to HOST:PORT [--listen 51900] [--profile lan|lte|hotel|bad|congested] [overrides]

  overrides: --delay ms  --jitter ms  --loss %  --burst (bursty loss)  --down mbit  --up mbit  --queue ms
             --outage-every s  --outage-ms ms  --seconds s (exit after; default: run until killed)

  profiles (one way; down = Mac → phone):
    lan        1 ms, no loss, no cap
    lte        35 ms ± 8, 0.5 % loss, 20 down / 8 up Mbit/s, 60 ms queue
    hotel      15 ms ± 15, 1 % bursty loss, 8 / 4 Mbit/s, 100 ms queue
    bad        60 ms ± 25, 3 % bursty loss, 4 / 2 Mbit/s, 150 ms queue
    congested  25 ms ± 5, 0.2 % loss, 6 / 3 Mbit/s, 300 ms queue (bufferbloat: delay before loss)
"""

struct Shape {
    var delayMs = 1.0, jitterMs = 0.0, loss = 0.0, burst = false
    var downMbps: Double?, upMbps: Double?
    var queueMs = 100.0
    var outageEvery: Double?, outageMs = 0.0

    static func named(_ n: String) -> Shape? {
        switch n {
        case "lan": Shape()
        case "lte": Shape(delayMs: 35, jitterMs: 8, loss: 0.005, downMbps: 20, upMbps: 8, queueMs: 60)
        case "hotel": Shape(delayMs: 15, jitterMs: 15, loss: 0.01, burst: true, downMbps: 8, upMbps: 4, queueMs: 100)
        case "bad": Shape(delayMs: 60, jitterMs: 25, loss: 0.03, burst: true, downMbps: 4, upMbps: 2, queueMs: 150)
        case "congested": Shape(delayMs: 25, jitterMs: 5, loss: 0.002, downMbps: 6, upMbps: 3, queueMs: 300)
        default: nil
        }
    }
}

func nowNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

/// One direction of the link. All state is on `queue`.
final class Direction: @unchecked Sendable {
    let name: String
    let shape: Shape
    let rateMbps: Double?
    let start = nowNs()
    private let queue: DispatchQueue
    private let deliver: @Sendable ([UInt8]) -> Void
    private var linkFreeAt: UInt64 = 0        // when the bottleneck finishes the queued bytes
    private var lastDelivery: UInt64 = 0
    private var bad = false
    private var rng = SystemRandomNumberGenerator()
    private(set) var counters = (packets: 0, bytes: 0, lost: 0, queueDrops: 0, outageDrops: 0, queueNsSum: UInt64(0))

    init(name: String, shape: Shape, rateMbps: Double?, deliver: @escaping @Sendable ([UInt8]) -> Void) {
        self.name = name
        self.shape = shape
        self.rateMbps = rateMbps
        self.deliver = deliver
        queue = DispatchQueue(label: "netsim.\(name)", qos: .userInteractive)
    }

    func submit(_ bytes: [UInt8]) {
        let arrival = nowNs()
        queue.async { [self] in process(bytes, arrival: arrival) }
    }

    func snapshot() -> (packets: Int, bytes: Int, lost: Int, queueDrops: Int, outageDrops: Int, queueNsSum: UInt64) {
        queue.sync { counters }
    }

    private func inOutage(_ t: UInt64) -> Bool {
        guard let every = shape.outageEvery, every > 0, shape.outageMs > 0 else { return false }
        let period = UInt64(every * 1e9), elapsed = t - start
        return elapsed > period && elapsed % period < UInt64(shape.outageMs * 1e6)
    }

    private func lose() -> Bool {
        guard shape.loss > 0 else { return false }
        let u = Double.random(in: 0..<1, using: &rng)
        guard shape.burst else { return u < shape.loss }
        // Gilbert-Elliott: everything lost in "bad", mean burst 3 packets, long-run loss = `loss`.
        let toGood = 1.0 / 3, toBad = shape.loss * toGood / max(1e-9, 1 - shape.loss)
        bad = bad ? u >= toGood : u < toBad
        return bad
    }

    private func process(_ bytes: [UInt8], arrival: UInt64) {
        counters.packets += 1
        counters.bytes += bytes.count
        if inOutage(arrival) { counters.outageDrops += 1; return }
        if lose() { counters.lost += 1; return }
        var departure = arrival
        if let rate = rateMbps {
            let start = max(arrival, linkFreeAt)
            let queued = start - arrival
            if Double(queued) / 1e6 > shape.queueMs { counters.queueDrops += 1; return }   // drop-tail
            let wire = UInt64(Double(bytes.count + 28) * 8 / (rate * 1e6) * 1e9)
            linkFreeAt = start + wire
            departure = linkFreeAt
            counters.queueNsSum += queued
        }
        let jitter = shape.jitterMs > 0 ? Double.random(in: 0...(2 * shape.jitterMs), using: &rng) - shape.jitterMs : 0
        let delay = max(0, shape.delayMs + jitter)
        let due = max(lastDelivery, departure + UInt64(delay * 1e6))   // no reordering
        lastDelivery = due
        let deliver = self.deliver
        queue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: due)) { deliver(bytes) }
    }
}

// MARK: helpers

func value(_ argv: [String], _ name: String) -> String? {
    guard let i = argv.firstIndex(of: "--\(name)"), i + 1 < argv.count else { return nil }
    return argv[i + 1]
}
func number(_ argv: [String], _ name: String) -> Double? { value(argv, name).flatMap(Double.init) }

func ipv4(_ host: String, _ port: UInt16) -> sockaddr_in? {
    var a = sockaddr_in()
    a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    a.sin_family = sa_family_t(AF_INET)
    a.sin_port = port.bigEndian
    guard inet_pton(AF_INET, host == "localhost" ? "127.0.0.1" : host, &a.sin_addr) == 1 else { return nil }
    return a
}

func check(_ r: Int32, _ what: String) {
    if r < 0 { print("\(what) failed: \(String(cString: strerror(errno)))"); exit(1) }
}

/// The phone's latest source address (it may change: roaming).
final class Peer: @unchecked Sendable {
    private let lock = NSLock()
    private var addr: sockaddr_in?
    func set(_ a: sockaddr_in) { lock.lock(); addr = a; lock.unlock() }
    func get() -> sockaddr_in? { lock.lock(); defer { lock.unlock() }; return addr }
}

func readLoop(_ fd: Int32, peer: Peer?, into dir: Direction) {
    let t = Thread {
        var buf = [UInt8](repeating: 0, count: 65_536)
        while true {
            var src = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = buf.withUnsafeMutableBytes { b in
                withUnsafeMutablePointer(to: &src) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, b.baseAddress, b.count, 0, $0, &len) } }
            }
            guard n > 0 else { continue }
            peer?.set(src)
            dir.submit(Array(buf[0..<n]))
        }
    }
    t.qualityOfService = .userInteractive
    t.start()
}

func describe(_ s: Shape) -> String {
    var parts = [String(format: "%.0f ms ± %.0f", s.delayMs, s.jitterMs), String(format: "loss %.1f %%%@", s.loss * 100, s.burst ? " bursty" : "")]
    parts.append("down \(s.downMbps.map { String(format: "%.0f", $0) } ?? "∞") / up \(s.upMbps.map { String(format: "%.0f", $0) } ?? "∞") Mbit/s, queue \(Int(s.queueMs)) ms")
    if let e = s.outageEvery { parts.append("outage \(Int(s.outageMs)) ms every \(Int(e)) s") }
    return parts.joined(separator: " · ")
}

final class Previous: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: (packets: Int, bytes: Int)] = [:]
    func swap(_ key: String, _ v: (packets: Int, bytes: Int)) -> (packets: Int, bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        let old = values[key] ?? (0, 0)
        values[key] = v
        return old
    }
}

// MARK: main

func run() {
    let argv = Array(CommandLine.arguments.dropFirst())
    guard let to = value(argv, "to"), let colon = to.lastIndex(of: ":"), let targetPort = UInt16(to[to.index(after: colon)...]) else {
        print(usage)
        exit(64)
    }
    let targetHost = String(to[..<colon])
    let listenPort = UInt16(number(argv, "listen") ?? 51900)
    let profileName = value(argv, "profile") ?? "lan"
    guard var shape = Shape.named(profileName) else { print("unknown profile \(profileName)\n\n\(usage)"); exit(64) }
    if let v = number(argv, "delay") { shape.delayMs = v }
    if let v = number(argv, "jitter") { shape.jitterMs = v }
    if let v = number(argv, "loss") { shape.loss = v / 100 }
    if argv.contains("--burst") { shape.burst = true }
    if let v = number(argv, "down") { shape.downMbps = v > 0 ? v : nil }
    if let v = number(argv, "up") { shape.upMbps = v > 0 ? v : nil }
    if let v = number(argv, "queue") { shape.queueMs = v }
    if let v = number(argv, "outage-every") { shape.outageEvery = v }
    if let v = number(argv, "outage-ms") { shape.outageMs = v }

    let listenFd = socket(AF_INET, SOCK_DGRAM, 0)
    let upstreamFd = socket(AF_INET, SOCK_DGRAM, 0)
    check(listenFd, "socket"); check(upstreamFd, "socket")
    var one: Int32 = 1
    setsockopt(listenFd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
    var bufSize: Int32 = 4 << 20
    for fd in [listenFd, upstreamFd] {
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
    }
    guard var bindAddr = ipv4("0.0.0.0", listenPort), var target = ipv4(targetHost, targetPort) else {
        print("need an IPv4 address for --to (got \(targetHost))"); exit(64)
    }
    check(withUnsafePointer(to: &bindAddr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }, "bind")
    check(withUnsafePointer(to: &target) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(upstreamFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }, "connect")

    let peer = Peer()
    let up = Direction(name: "up", shape: shape, rateMbps: shape.upMbps) { bytes in
        _ = bytes.withUnsafeBytes { send(upstreamFd, $0.baseAddress, bytes.count, 0) }
    }
    let down = Direction(name: "down", shape: shape, rateMbps: shape.downMbps) { bytes in
        guard var a = peer.get() else { return }
        _ = bytes.withUnsafeBytes { b in
            withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(listenFd, b.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
    }

    readLoop(listenFd, peer: peer, into: up)
    readLoop(upstreamFd, peer: nil, into: down)

    print("netsim \(profileName): 0.0.0.0:\(listenPort) → \(targetHost):\(targetPort) · \(describe(shape))")
    setvbuf(stdout, nil, _IOLBF, 0)

    let report = DispatchSource.makeTimerSource(queue: .global())
    let previous = Previous()
    report.schedule(deadline: .now() + 5, repeating: 5)
    report.setEventHandler {
        var line: [String] = []
        for d in [down, up] {
            let c = d.snapshot()
            let p = previous.swap(d.name, (c.packets, c.bytes))
            let mbps = Double(c.bytes - p.bytes) * 8 / 5 / 1e6
            let avgQueue = c.packets > 0 ? Double(c.queueNsSum) / Double(max(1, c.packets - c.lost - c.queueDrops - c.outageDrops)) / 1e6 : 0
            line.append("\(d.name) \(String(format: "%.1f", mbps)) Mbit/s, \(c.packets) pkts, lost \(c.lost), queue drops \(c.queueDrops), outage \(c.outageDrops), avg queue \(String(format: "%.1f", avgQueue)) ms")
        }
        print(line.joined(separator: " | "))
    }
    report.resume()

    if let seconds = number(argv, "seconds") {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
    }
    dispatchMain()
}

run()
