/// Rate limits on handshake initiations (docs/security.md T8). Checking a msg1 costs the Mac a DH before it
/// knows who sent it, so a flood is CPU, not just bandwidth: per source address 30 a minute (burst 30), and
/// 200 a second across all sources. Over the limit, packets are dropped silently like any other bad packet.
public struct HandshakeLimiter: Sendable {
    public static let perHostBurst = 30.0
    public static let perHostPerSecond = 30.0 / 60
    public static let globalBurst = 200.0
    public static let globalPerSecond = 200.0
    /// Distinct sources tracked before idle ones are forgotten.
    public static let maxHosts = 4096

    struct Bucket: Sendable {
        var tokens: Double
        var lastNs: UInt64
        mutating func take(capacity: Double, perSecond: Double, nowNs: UInt64) -> Bool {
            let elapsed = Double(nowNs &- lastNs) / 1e9
            if nowNs > lastNs { tokens = min(capacity, tokens + elapsed * perSecond) }
            lastNs = max(lastNs, nowNs)
            guard tokens >= 1 else { return false }
            tokens -= 1
            return true
        }
    }

    private var hosts: [String: Bucket] = [:]
    private var global: Bucket
    public private(set) var refused = 0

    public init(nowNs: UInt64 = 0) {
        global = Bucket(tokens: Self.globalBurst, lastNs: nowNs)
    }

    public mutating func allow(host: String, nowNs: UInt64) -> Bool {
        if hosts.count >= Self.maxHosts { prune(nowNs: nowNs) }
        var b = hosts[host] ?? Bucket(tokens: Self.perHostBurst, lastNs: nowNs)
        let hostOK = b.take(capacity: Self.perHostBurst, perSecond: Self.perHostPerSecond, nowNs: nowNs)
        hosts[host] = b
        guard hostOK, global.take(capacity: Self.globalBurst, perSecond: Self.globalPerSecond, nowNs: nowNs) else {
            refused += 1
            return false
        }
        return true
    }

    /// Forgets sources whose bucket has refilled (they've been quiet for a minute); if every source is
    /// busy (a spoofed-address flood), forgets them all rather than grow.
    private mutating func prune(nowNs: UInt64) {
        let refill = UInt64(Self.perHostBurst / Self.perHostPerSecond * 1e9)
        hosts = hosts.filter { nowNs &- $0.value.lastNs < refill }
        if hosts.count >= Self.maxHosts { hosts.removeAll() }
    }
}
