import AppIntents
import Foundation

/// "Connect to my Mac" for Siri, Shortcuts, the widget and the Control Center control (1.1). Compiled into
/// the app and the widget extension; it only opens the app at `clamshell://connect`, so the extension needs
/// no shared storage (a free Apple Account can't use App Groups) and the app does the connecting.
/// Where an intent's request goes when it runs inside the app (Siri, Shortcuts, the Control Center
/// control): straight to the controller, because the app doesn't reliably get an `OpenURLIntent` for its
/// own URL scheme while it's the one being opened. In the widget extension there's no app to call, so the
/// intent opens the URL instead.
@MainActor
enum AppLinks {
    static var handler: ((URL) -> Void)?
    /// A request that arrived before the app's view set `handler` (a cold launch).
    static var pending: URL?

    static var inApp: Bool { !Bundle.main.bundleURL.pathExtension.lowercased().contains("appex") }

    /// Delivers `url` in the app; false when this is the extension and the URL has to be opened.
    static func deliver(_ url: URL) -> Bool {
        guard inApp else { return false }
        if let handler { handler(url) } else { pending = url }
        return true
    }
}

struct ConnectToMacIntent: AppIntent {
    static let title: LocalizedStringResource = "Connect to My Mac"
    static let description = IntentDescription("Opens Clamshell and connects to your Mac: on this Wi-Fi if it's there, else at its away-from-home address.")
    static let openAppWhenRun = true

    @Parameter(title: "Mac name", description: "Leave empty for the Mac chosen in the app.")
    var macName: String?

    init() {}
    init(macName: String?) { self.macName = macName }

    func perform() async throws -> some IntentResult & OpensIntent {
        var parts = URLComponents()
        parts.scheme = "clamshell"
        parts.host = "connect"
        if let macName, !macName.isEmpty { parts.queryItems = [URLQueryItem(name: "mac", value: macName)] }
        guard let url = parts.url else { return .result() }
        if await AppLinks.deliver(url) { return .result() }
        return .result(opensIntent: OpenURLIntent(url))
    }
}

struct DisconnectFromMacIntent: AppIntent {
    static let title: LocalizedStringResource = "Disconnect from My Mac"
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & OpensIntent {
        guard let url = URL(string: "clamshell://disconnect") else { return .result() }
        if await AppLinks.deliver(url) { return .result() }
        return .result(opensIntent: OpenURLIntent(url))
    }
}
