import AppKit
import ClamshellWire

/// Clipboard sync with the phone (off by default: `defaults write <bundle id> clipboardSync -bool true`,
/// or the menu toggle). Polls the pasteboard's change count every 0.5 s; text and PNG/TIFF images only.
@MainActor
final class ClipboardSync {
    private var timer: Timer?
    private var lastChange = NSPasteboard.general.changeCount
    private let send: (ClipboardOffer) -> Void

    init(send: @escaping (ClipboardOffer) -> Void) { self.send = send }

    func start() {
        lastChange = NSPasteboard.general.changeCount        // don't push what was there before the session
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in MainActor.assumeIsolated { self.poll() } }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        // Password managers mark secrets as concealed; those never leave the Mac (M5).
        if ClipboardPolicy.shouldSkip(types: (pb.types ?? []).map(\.rawValue)) { return }
        var items: [ClipboardItem] = []
        if let s = pb.string(forType: .string) { items.append(ClipboardItem(uti: "public.utf8-plain-text", data: Array(s.utf8))) }
        if let png = pb.data(forType: .png) {
            items.append(ClipboardItem(uti: "public.png", data: [UInt8](png)))
        } else if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            items.append(ClipboardItem(uti: "public.png", data: [UInt8](png)))
        }
        items = ClipboardPolicy.filter(items)
        let total = items.reduce(0) { $0 + $1.data.count }
        guard !items.isEmpty, total < BulkSender.maxBytes - 1024 else { return }
        send(ClipboardOffer(items: items, changeCount: UInt64(pb.changeCount)))
    }

    /// From the phone.
    func apply(_ offer: ClipboardOffer) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let text = offer.text { pb.setString(text, forType: .string) }
        if let png = offer.items.first(where: { $0.uti == "public.png" }) { pb.setData(Data(png.data), forType: .png) }
        lastChange = pb.changeCount                          // not an echo back to the phone
    }
}
