import Foundation

/// What the router says about its internet side.
public struct WANReading: Equatable, Sendable {
    public let address: IPv4
    /// The router's name for the connection, e.g. "pppoe_ptm_0_1_d".
    public let connection: String
}

public enum RouterError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Couldn't reach the router's web UI (not on the home network, or the router is restarting).
    case unreachable(String)
    /// Someone is signed in to the router's web UI. Signing in would throw them out, so we wait.
    case someoneSignedIn
    /// The router turned the password down (`code` is its `$.ret`). Don't try again with it: a few
    /// wrong tries lock the web UI for everyone.
    case wrongPassword(code: Int)
    /// An answer we didn't understand. `detail` is safe to log (no password or keys in it).
    case unexpected(String)
    /// Signed in fine, but no internet connection is up.
    case notConnected

    public var description: String {
        switch self {
        case .unreachable(let why): "router not reachable (\(why))"
        case .someoneSignedIn: "someone is signed in to the router; trying again later"
        case .wrongPassword(let code): "the router turned the password down (code \(code))"
        case .unexpected(let detail): "unexpected router answer: \(detail)"
        case .notConnected: "the router's internet connection is down"
        }
    }
}

/// Reads the WAN address from a TP-Link Archer VR400 (and VR/MR models with the same web UI) by signing
/// in like the browser does, asking for the WAN connections, and signing out again. Every reading uses a
/// fresh, in-memory cookie jar.
public struct TPLinkRouter: Sendable {
    public let host: String
    let log: @Sendable (String) -> Void

    public init(host: String = "192.168.1.1", log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.host = host
        self.log = log
    }

    public func readWAN(password: String) async throws -> WANReading {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.httpCookieAcceptPolicy = .always
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        guard let parm = TPLinkMessages.parameters(try await text(session, post: "/cgi/getParm")) else {
            throw RouterError.unexpected("getParm had no key")
        }
        let busy = try await text(session, post: "/cgi/getBusy")
        if TPLinkMessages.someoneSignedIn(busy) == true { throw RouterError.someoneSignedIn }

        let enc = TPLinkEncryptor(key: TPLinkEncryptor.randomDigits(16), iv: TPLinkEncryptor.randomDigits(16),
                                  password: password, rsa: parm.rsa)
        guard let login = enc.seal("admin\n" + password, seq: parm.seq, login: true) else {
            throw RouterError.unexpected("couldn't encrypt the sign-in")
        }
        let loginPath = "/cgi/login?data=\(Self.uriComponent(login.data))&sign=\(login.sign)&Action=1&LoginStatus=0&isMobile=0"
        let loginAnswer = try await text(session, post: loginPath)
        guard let ret = TPLinkMessages.loginResult(loginAnswer) else {
            throw RouterError.unexpected("sign-in answer without a result: \(Self.snippet(loginAnswer))")
        }
        guard ret == 0 else { throw RouterError.wrongPassword(code: ret) }

        // Signed in: from here on, always sign out again, so the session doesn't sit there blocking the
        // web UI for someone else.
        let page = (try? await text(session, get: "/")) ?? ""
        let token = TPLinkMessages.token(inPage: page)
        if token == nil { log("router: no token on the main page (\(page.count) bytes); sending 0") }
        let seq = (try? TPLinkMessages.parameters(await text(session, post: "/cgi/getParm", token: token)))?.seq ?? parm.seq

        do {
            let reading = try await wan(session, enc: enc, seq: seq, fallbackSeq: parm.seq, token: token)
            await logout(session, enc: enc, seq: seq, token: token)
            return reading
        } catch {
            await logout(session, enc: enc, seq: seq, token: token)
            throw error
        }
    }

    private func wan(_ session: URLSession, enc: TPLinkEncryptor, seq: Int, fallbackSeq: Int,
                     token: String?) async throws -> WANReading {
        var lastDetail = ""
        for s in (seq == fallbackSeq ? [seq] : [seq, fallbackSeq]) {
            guard let sealed = enc.seal(TPLinkMessages.wanRequest, seq: s, login: false) else {
                throw RouterError.unexpected("couldn't encrypt the request")
            }
            let body = "sign=\(sealed.sign)\r\ndata=\(sealed.data)\r\n"
            let answer = try await text(session, post: "/cgi_gdpr", body: body, token: token)
            let plain = enc.open(answer) ?? answer
            guard let parsed = TPLinkMessages.response(plain) else {
                lastDetail = "seq \(s == seq ? "fresh" : "login"): \(Self.snippet(plain))"
                log("router: WAN answer not understood (\(lastDetail))")
                continue
            }
            guard parsed.error == 0 else {
                lastDetail = "error \(parsed.error)"
                log("router: WAN request \(lastDetail)")
                continue
            }
            return try Self.pick(parsed.instances)
        }
        throw RouterError.unexpected(lastDetail)
    }

    /// The first connected PPP connection with an IPv4 address, else the first connected IP one.
    static func pick(_ instances: [TPLinkMessages.Instance]) throws -> WANReading {
        let up = instances
            .filter { $0.values["connectionStatus"]?.lowercased() == "connected" && $0.values["enable"] != "0" }
            .sorted { $0.action < $1.action }
        for i in up {
            if let ip = i.values["externalIPAddress"].flatMap(IPv4.init), ip.description != "0.0.0.0" {
                return WANReading(address: ip, connection: i.values["name"] ?? i.stack)
            }
        }
        throw RouterError.notConnected
    }

    private func logout(_ session: URLSession, enc: TPLinkEncryptor, seq: Int, token: String?) async {
        guard let sealed = enc.seal(TPLinkMessages.logoutRequest, seq: seq, login: false) else { return }
        _ = try? await text(session, post: "/cgi_gdpr", body: "sign=\(sealed.sign)\r\ndata=\(sealed.data)\r\n", token: token)
    }

    // MARK: HTTP

    private func text(_ session: URLSession, post path: String, body: String? = nil, token: String? = nil) async throws -> String {
        try await text(session, method: "POST", path: path, body: body, token: token)
    }

    private func text(_ session: URLSession, get path: String) async throws -> String {
        try await text(session, method: "GET", path: path, body: nil, token: nil)
    }

    private func text(_ session: URLSession, method: String, path: String, body: String?, token: String?) async throws -> String {
        guard let url = URL(string: "http://\(host)\(path)") else { throw RouterError.unexpected("bad router address") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("http://\(host)/", forHTTPHeaderField: "Referer")
        req.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue(token, forHTTPHeaderField: "TokenID") }
        if let body { req.httpBody = Data(body.utf8) }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw RouterError.unreachable((error as NSError).localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw RouterError.unexpected("HTTP \(status) from \(path.prefix { $0 != "?" })") }
        return String(decoding: data, as: UTF8.self)
    }

    /// JavaScript's `encodeURIComponent`.
    static func uriComponent(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)..<Unicode.Scalar(128)))
        allowed.insert(charactersIn: "-_.!~*'()")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// The start of an answer, for the log. Answers never contain the password.
    static func snippet(_ s: String) -> String {
        let flat = s.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "⏎")
        return flat.count > 160 ? String(flat.prefix(160)) + "…" : flat
    }
}
