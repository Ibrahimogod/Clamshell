import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum PortProtocol: String, Sendable, CaseIterable {
    case udp = "UDP", tcp = "TCP"
}

/// One forward on the router: `externalPort` on its public side goes to `internalClient:internalPort`.
public struct PortMapping: Equatable, Sendable {
    public var externalPort: UInt16
    public var proto: PortProtocol
    public var internalPort: UInt16
    public var internalClient: String
    public var description: String
    /// Seconds; 0 is a permanent mapping.
    public var leaseSeconds: Int

    public init(externalPort: UInt16, proto: PortProtocol, internalPort: UInt16, internalClient: String,
                description: String, leaseSeconds: Int) {
        self.externalPort = externalPort
        self.proto = proto
        self.internalPort = internalPort
        self.internalClient = internalClient
        self.description = description
        self.leaseSeconds = leaseSeconds
    }
}

/// A UPnP error code from the router (UPnP IGD WANIPConnection §2.4), or a transport failure (`code` < 0).
public struct UPnPError: Error, Equatable, Sendable, CustomStringConvertible {
    public let code: Int
    public let text: String

    public static let noSuchEntry = 714
    public static let conflict = 718
    public static let onlyPermanentLeases = 725
    public static let notAuthorized = 606

    public init(code: Int, text: String) {
        self.code = code
        self.text = text
    }

    public var description: String { code < 0 ? text : "UPnP error \(code) \(text)" }
}

/// The text side of UPnP: the SSDP search, the device description, and SOAP requests and answers.
enum UPnPMessages {
    static let deviceTypes = [
        "urn:schemas-upnp-org:device:InternetGatewayDevice:1",
        "urn:schemas-upnp-org:device:InternetGatewayDevice:2",
    ]
    /// The services that can map ports, best first.
    static let serviceTypes = [
        "urn:schemas-upnp-org:service:WANIPConnection:2",
        "urn:schemas-upnp-org:service:WANIPConnection:1",
        "urn:schemas-upnp-org:service:WANPPPConnection:1",
    ]

    static func search(_ target: String) -> String {
        "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: \(target)\r\n\r\n"
    }

    /// The `LOCATION:` header of an SSDP answer.
    static func location(_ answer: String) -> URL? {
        for line in answer.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":"),
                  line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "location" else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let url = URL(string: value), url.scheme == "http", url.host != nil { return url }
        }
        return nil
    }

    /// The port-mapping service in a device description, and its absolute control URL.
    static func connectionService(_ xml: String, location: URL) -> (type: String, control: URL)? {
        let base = text(of: "URLBase", in: xml).flatMap(URL.init(string:)) ?? location
        var found: [(type: String, control: URL)] = []
        for block in blocks("service", in: xml) {
            guard let type = text(of: "serviceType", in: block), serviceTypes.contains(type),
                  let path = text(of: "controlURL", in: block),
                  let control = URL(string: path, relativeTo: base)?.absoluteURL else { continue }
            found.append((type, control))
        }
        return serviceTypes.lazy.compactMap { t in found.first { $0.type == t } }.first
    }

    static func envelope(_ action: String, service: String, _ arguments: KeyValuePairs<String, String>) -> String {
        var args = ""
        for (k, v) in arguments { args += "<\(k)>\(escape(v))</\(k)>" }
        return "<?xml version=\"1.0\"?>\r\n<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" "
            + "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body>"
            + "<u:\(action) xmlns:u=\"\(service)\">\(args)</u:\(action)></s:Body></s:Envelope>\r\n"
    }

    enum Answer: Equatable {
        case ok([String: String])
        case fault(code: Int, text: String)
    }

    /// A SOAP answer: the `New…` values of a response, or the UPnP error of a fault. Nil if it's neither.
    static func answer(_ xml: String) -> Answer? {
        if xml.contains("Fault>") || xml.contains("<errorCode>") {
            let code = text(of: "errorCode", in: xml).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? -1
            return .fault(code: code, text: text(of: "errorDescription", in: xml) ?? "")
        }
        guard xml.contains("Response") else { return nil }
        var values: [String: String] = [:]
        var rest = Substring(xml)
        while let open = rest.range(of: "<New") {
            guard let close = rest[open.upperBound...].firstIndex(of: ">") else { break }
            let name = "New" + rest[open.upperBound..<close]
            guard name.allSatisfy({ $0.isLetter || $0.isNumber }),
                  let end = rest[close...].range(of: "</\(name)>") else { rest = rest[close...]; continue }
            values[name] = unescape(String(rest[rest.index(after: close)..<end.lowerBound]))
            rest = rest[end.upperBound...]
        }
        return .ok(values)
    }

    // MARK: tiny XML helpers (the documents are small and flat enough for this)

    /// The text inside the first `<name>…</name>` (namespace prefixes on the tag are allowed).
    static func text(of name: String, in xml: some StringProtocol) -> String? {
        for open in ["<\(name)>", ":\(name)>"] {
            guard let start = xml.range(of: open)?.upperBound,
                  let end = xml[start...].range(of: "</")?.lowerBound else { continue }
            return unescape(xml[start..<end].trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    static func blocks(_ name: String, in xml: String) -> [Substring] {
        var out: [Substring] = []
        var rest = Substring(xml)
        while let open = rest.range(of: "<\(name)>"), let close = rest[open.upperBound...].range(of: "</\(name)>") {
            out.append(rest[open.upperBound..<close.lowerBound])
            rest = rest[close.upperBound...]
        }
        return out
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// The router's UPnP port-mapping service (Internet Gateway Device). Found with an SSDP search, then
/// driven with SOAP requests over plain HTTP on the home network.
public struct UPnPGateway: Sendable, Equatable {
    public let serviceType: String
    public let controlURL: URL

    public init(serviceType: String, controlURL: URL) {
        self.serviceType = serviceType
        self.controlURL = controlURL
    }

    /// Searches for the gateway (asking `gateway` directly and the SSDP multicast group), then reads its
    /// description. Nil if nothing answers: UPnP is off on the router, or there's no such router.
    public static func discover(gateway: String, timeout: TimeInterval = 2) async -> UPnPGateway? {
        let answers = await Task.detached {
            ssdp(UPnPMessages.deviceTypes.map(UPnPMessages.search), to: [gateway, "239.255.255.250"], timeout: timeout)
        }.value
        let locations = answers.compactMap(UPnPMessages.location)
        // The router itself first; another UPnP gateway on the network (a mesh node, say) only as a fallback.
        let ordered = locations.filter { $0.host == gateway } + locations.filter { $0.host != gateway }
        var seen = Set<URL>()
        for url in ordered where seen.insert(url).inserted {
            var req = URLRequest(url: url, timeoutInterval: 5)
            req.httpMethod = "GET"
            guard let (data, _) = try? await session.data(for: req),
                  let service = UPnPMessages.connectionService(String(decoding: data, as: UTF8.self), location: url) else { continue }
            return UPnPGateway(serviceType: service.type, controlURL: service.control)
        }
        return nil
    }

    /// The mapping on `port`, or nil if there's none.
    public func mapping(_ port: UInt16, _ proto: PortProtocol) async throws -> PortMapping? {
        do {
            let v = try await call("GetSpecificPortMappingEntry", [
                "NewRemoteHost": "", "NewExternalPort": String(port), "NewProtocol": proto.rawValue,
            ])
            return PortMapping(externalPort: port, proto: proto,
                               internalPort: UInt16(v["NewInternalPort"] ?? "") ?? 0,
                               internalClient: v["NewInternalClient"] ?? "",
                               description: v["NewPortMappingDescription"] ?? "",
                               leaseSeconds: Int(v["NewLeaseDuration"] ?? "") ?? 0)
        } catch let e as UPnPError where e.code == UPnPError.noSuchEntry {
            return nil
        }
    }

    public func add(_ m: PortMapping) async throws {
        _ = try await call("AddPortMapping", [
            "NewRemoteHost": "", "NewExternalPort": String(m.externalPort), "NewProtocol": m.proto.rawValue,
            "NewInternalPort": String(m.internalPort), "NewInternalClient": m.internalClient, "NewEnabled": "1",
            "NewPortMappingDescription": m.description, "NewLeaseDuration": String(m.leaseSeconds),
        ])
    }

    public func delete(_ port: UInt16, _ proto: PortProtocol) async throws {
        _ = try await call("DeletePortMapping", ["NewRemoteHost": "", "NewExternalPort": String(port), "NewProtocol": proto.rawValue])
    }

    public func externalAddress() async throws -> String? {
        try await call("GetExternalIPAddress", [:])["NewExternalIPAddress"]
    }

    private func call(_ action: String, _ arguments: KeyValuePairs<String, String>) async throws -> [String: String] {
        var req = URLRequest(url: controlURL, timeoutInterval: 5)
        req.httpMethod = "POST"
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\"\(serviceType)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        req.httpBody = Data(UPnPMessages.envelope(action, service: serviceType, arguments).utf8)
        let data: Data
        do {
            (data, _) = try await Self.session.data(for: req)
        } catch {
            throw UPnPError(code: -1, text: "router not reachable (\((error as NSError).localizedDescription))")
        }
        // Faults come with HTTP 500, so the body decides, not the status.
        switch UPnPMessages.answer(String(decoding: data, as: UTF8.self)) {
        case .ok(let values): return values
        case .fault(let code, let text): throw UPnPError(code: code, text: text)
        case nil: throw UPnPError(code: -2, text: "unexpected answer to \(action)")
        }
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 5
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    // MARK: sockets

    /// The Mac's own address on the network that leads to `host` (what the router should forward to).
    public static func localAddress(toward host: String) -> String? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var to = sockaddr_in(host, port: 1900)
        guard to.sin_addr.s_addr != 0,
              withUnsafePointer(to: &to, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                  connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }) == 0 else { return nil }
        var me = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &me, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(fd, $0, &len) } }) == 0 else { return nil }
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &me.sin_addr, &buf, socklen_t(buf.count)) != nil else { return nil }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Sends each search to each host on port 1900 from one unconnected socket (answers come back from
    /// another port than 1900, so a connected socket would drop them) and collects answers until `timeout`.
    static func ssdp(_ messages: [String], to hosts: [String], timeout: TimeInterval) -> [String] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var tv = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        for host in hosts {
            var to = sockaddr_in(host, port: 1900)
            guard to.sin_addr.s_addr != 0 else { continue }
            for m in messages {
                let bytes = Array(m.utf8)
                _ = withUnsafePointer(to: &to) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            }
        }
        var answers: [String] = []
        var buf = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let n = recv(fd, &buf, buf.count, 0)
            if n > 0 {
                answers.append(String(decoding: buf[..<n], as: UTF8.self))
                // One answer from the router is enough; a short grace period catches the rest.
                if answers.count >= 4 { break }
            }
        }
        return answers
    }
}

private extension sockaddr_in {
    init(_ host: String, port: UInt16) {
        self.init()
        sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin_family = sa_family_t(AF_INET)
        sin_port = port.bigEndian
        if inet_pton(AF_INET, host, &sin_addr) != 1 { sin_addr.s_addr = 0 }
    }
}
