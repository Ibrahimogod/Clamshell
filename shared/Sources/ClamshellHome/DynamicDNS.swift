import Foundation

/// Keeps a dynamic DNS name pointed at the home address, so phones find the Mac after it changes.
/// The service learns the home IP and nothing else: no traffic goes through it, and a forged record only
/// leads to a failed, authenticated handshake.
///
/// - **DuckDNS** (free, `name.duckdns.org`):
///   `GET https://www.duckdns.org/update?domains=<name>&token=…&ip=<ipv4>&verbose=true` → `OK…` / `KO`.
/// - **deSEC** (for your own domain hosted there; its free dedyn.io names are closed to new accounts):
///   `GET https://update.dedyn.io/?hostname=…&myipv4=…&myipv6=` with `Authorization: Token …`.
public enum DynamicDNS {
    public enum Provider: String, Sendable { case duckDNS = "DuckDNS", deSEC = "deSEC" }

    public enum Outcome: Equatable, Sendable, CustomStringConvertible {
        case updated
        /// The token was turned down (wrong, or the name isn't on that account). Don't retry until it changes.
        case badAuth
        /// Too many updates; the service says when to try again.
        case throttled(retryAfter: TimeInterval?)
        case failed(String)

        public var description: String {
            switch self {
            case .updated: "updated"
            case .badAuth: "the token or name was turned down"
            case .throttled(let after): "asked to wait" + (after.map { " \(Int($0)) s" } ?? "")
            case .failed(let why): "update failed (\(why))"
            }
        }
    }

    /// Lower-cased and trimmed; a bare name like `myhome` becomes `myhome.duckdns.org`.
    public static func normalize(_ name: String) -> String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return n.isEmpty || n.contains(".") ? n : n + ".duckdns.org"
    }

    public static func provider(for hostname: String) -> Provider {
        normalize(hostname).hasSuffix(".duckdns.org") ? .duckDNS : .deSEC
    }

    /// A DNS name: letters, digits and hyphens in dot-separated labels, at least two, not all-numeric TLD.
    public static func isHostname(_ s: String) -> Bool {
        let labels = s.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, s.count <= 253 else { return false }
        return labels.allSatisfy { l in
            !l.isEmpty && l.count <= 63 && l.first != "-" && l.last != "-"
                && l.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        } && !(labels.last?.allSatisfy(\.isNumber) ?? true)
    }

    public static func request(hostname: String, address: IPv4, token: String) -> URLRequest? {
        let name = normalize(hostname)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isHostname(name), !token.isEmpty else { return nil }
        var c = URLComponents()
        c.scheme = "https"
        c.path = "/update"
        var req: URLRequest
        switch provider(for: name) {
        case .duckDNS:
            let sub = String(name.dropLast(".duckdns.org".count))
            guard !sub.isEmpty, !sub.contains(".") else { return nil }
            c.host = "www.duckdns.org"
            c.queryItems = [URLQueryItem(name: "domains", value: sub), URLQueryItem(name: "token", value: token),
                            URLQueryItem(name: "ip", value: address.description), URLQueryItem(name: "verbose", value: "true")]
            guard let url = c.url else { return nil }
            req = URLRequest(url: url)
        case .deSEC:
            c.host = "update.dedyn.io"
            c.path = "/"
            // An empty myipv6 removes any IPv6 record, so phones never try an address the router doesn't forward.
            c.queryItems = [URLQueryItem(name: "hostname", value: name), URLQueryItem(name: "myipv4", value: address.description),
                            URLQueryItem(name: "myipv6", value: "")]
            guard let url = c.url else { return nil }
            req = URLRequest(url: url)
            req.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 15
        return req
    }

    public static func outcome(_ provider: Provider, status: Int, body: String, retryAfter: String?) -> Outcome {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (provider, status) {
        case (.duckDNS, 200) where text.hasPrefix("OK"): return .updated
        case (.duckDNS, 200) where text.hasPrefix("KO"): return .badAuth
        case (.deSEC, 200) where text.hasPrefix("good") || text.hasPrefix("nochg"): return .updated
        case (_, 401), (_, 403): return .badAuth
        case (_, 429): return .throttled(retryAfter: retryAfter.flatMap(TimeInterval.init))
        default: return .failed("HTTP \(status) \(text.prefix(80))")
        }
    }

    public static func update(hostname: String, address: IPv4, token: String) async -> Outcome {
        guard let req = request(hostname: hostname, address: address, token: token) else {
            return .failed("bad name or empty token")
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: req)
            let http = response as? HTTPURLResponse
            return outcome(provider(for: hostname), status: http?.statusCode ?? 0, body: String(decoding: data, as: UTF8.self),
                           retryAfter: http?.value(forHTTPHeaderField: "Retry-After"))
        } catch {
            // URLError descriptions don't include the URL (which holds the DuckDNS token).
            return .failed((error as? URLError).map { "network error \($0.code.rawValue)" } ?? "network error")
        }
    }
}
