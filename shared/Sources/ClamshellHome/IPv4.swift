import Foundation

/// Dotted-quad IPv4 addresses and the ranges that can't be reached from the internet.
public struct IPv4: Hashable, Sendable, CustomStringConvertible {
    public let octets: (UInt8, UInt8, UInt8, UInt8)

    public init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var o: [UInt8] = []
        for p in parts {
            guard !p.isEmpty, p.count <= 3, p.allSatisfy(\.isASCII), let v = UInt8(p) else { return nil }
            o.append(v)
        }
        octets = (o[0], o[1], o[2], o[3])
    }

    public var description: String { "\(octets.0).\(octets.1).\(octets.2).\(octets.3)" }

    /// 100.64.0.0/10: the ISP's carrier-grade NAT. Port forwarding on the router can't work behind it.
    public var isCarrierNAT: Bool { octets.0 == 100 && octets.1 & 0xC0 == 64 }

    /// An address the internet can send to: not private, carrier NAT, loopback, link-local or reserved.
    public var isPublic: Bool {
        let (a, b, _, _) = octets
        switch a {
        case 0, 10, 127, 224...255: return false
        case 100 where isCarrierNAT: return false
        case 169 where b == 254: return false
        case 172 where (16...31).contains(b): return false
        case 192 where b == 168: return false
        default: return true
        }
    }

    public static func == (l: IPv4, r: IPv4) -> Bool { l.description == r.description }
    public func hash(into h: inout Hasher) { h.combine(description) }
}
