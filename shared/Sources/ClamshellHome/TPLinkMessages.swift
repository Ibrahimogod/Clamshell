import Foundation

/// The text formats the TP-Link web UI exchanges with the router: small JavaScript snippets from the
/// `/cgi/...` endpoints, and the line-based object requests sent to `/cgi_gdpr`.
enum TPLinkMessages {
    // Action codes from the web UI (ACT_GET … ACT_CGI).
    static let actGetList = 5
    static let actCGI = 8

    /// `var name="value";` and `$.ret=0;` assignments, as a dictionary (`$.ret` becomes `ret`).
    static func assignments(_ js: String) -> [String: String] {
        var out: [String: String] = [:]
        for statement in js.split(whereSeparator: { $0 == ";" || $0.isNewline }) {
            var s = statement.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("var ") { s.removeFirst(4) }
            if s.hasPrefix("$.") { s.removeFirst(2) }
            guard let eq = s.firstIndex(of: "=") else { continue }
            let name = s[..<eq].trimmingCharacters(in: .whitespaces)
            var value = s[s.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { continue }
            if value.count >= 2, let f = value.first, f == "\"" || f == "'", value.last == f {
                value = String(value.dropFirst().dropLast())
            }
            out[name] = value
        }
        return out
    }

    /// `/cgi/getParm`: the router's RSA key and the sequence number signatures count from.
    static func parameters(_ js: String) -> (rsa: RawRSA, seq: Int)? {
        let a = assignments(js)
        guard let nn = a["nn"], let ee = a["ee"], let seqText = a["seq"], let seq = Int(seqText),
              let rsa = RawRSA(modulusHex: nn, exponentHex: ee) else { return nil }
        return (rsa, seq)
    }

    /// `/cgi/getBusy`: whether someone is signed in to the web UI (signing in would throw them out).
    static func someoneSignedIn(_ js: String) -> Bool? {
        assignments(js)["isLogined"].flatMap(Int.init).map { $0 != 0 }
    }

    /// The `$.ret` code from `/cgi/login` (0 = signed in).
    static func loginResult(_ js: String) -> Int? {
        assignments(js)["ret"].flatMap(Int.init)
    }

    /// The session token the signed-in main page hands its scripts (sent back as the `TokenID` header).
    static func token(inPage html: String) -> String? {
        for name in ["token", "tokenid", "tokenId"] {
            for quote in ["\"", "'"] {
                let marker = "var \(name)=\(quote)"
                let compact = html.replacingOccurrences(of: "var \(name) = \(quote)", with: marker)
                guard let start = compact.range(of: marker)?.upperBound,
                      let end = compact[start...].firstIndex(of: Character(quote)) else { continue }
                let value = String(compact[start..<end])
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    struct Action: Sendable {
        let type: Int
        let object: String
        let attributes: [String]
    }

    /// The `/cgi_gdpr` request text: a line of action codes joined by `&`, then for each action
    /// `[OBJECT#stack#parent stack]index,count` and its attribute names, every line ending in CRLF.
    static func request(_ actions: [Action]) -> String {
        var s = actions.map { String($0.type) }.joined(separator: "&") + "\r\n"
        for (i, a) in actions.enumerated() {
            s += "[\(a.object)#0,0,0,0,0,0#0,0,0,0,0,0]\(i),\(a.attributes.count)\r\n"
            for attr in a.attributes { s += attr + "\r\n" }
        }
        return s
    }

    static let wanRequest = request([
        Action(type: actGetList, object: "WAN_PPP_CONN", attributes: ["enable", "name", "connectionStatus", "externalIPAddress"]),
        Action(type: actGetList, object: "WAN_IP_CONN", attributes: ["enable", "name", "connectionStatus", "externalIPAddress"]),
    ])

    static let logoutRequest = request([Action(type: actCGI, object: "/cgi/logout", attributes: [])])

    struct Instance: Equatable, Sendable {
        /// Which action of the request this answers.
        var action: Int
        var stack: String
        var values: [String: String]
    }

    /// Parses a `/cgi_gdpr` answer: `[stack]actionIndex` headers, `name=value` lines, and a final
    /// `[error]code`. Returns nil if there's no `[error]` line at all (not an answer of this kind).
    static func response(_ text: String) -> (instances: [Instance], error: Int)? {
        var instances: [Instance] = []
        var current: Instance?
        var error: Int?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                if let c = current { instances.append(c) }
                current = nil
                let inside = String(line[line.index(after: line.startIndex)..<close])
                let rest = String(line[line.index(after: close)...])
                if inside == "error" {
                    error = Int(rest) ?? -1
                } else {
                    current = Instance(action: Int(rest) ?? -1, stack: inside, values: [:])
                }
            } else if let eq = line.firstIndex(of: "="), current != nil {
                current?.values[String(line[..<eq])] = String(line[line.index(after: eq)...])
            }
        }
        if let c = current { instances.append(c) }
        guard let error else { return nil }
        return (instances, error)
    }
}
