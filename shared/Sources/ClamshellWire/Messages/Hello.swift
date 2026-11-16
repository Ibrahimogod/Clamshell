/// Capability bits advertised in `Hello` (ADR-0011). Bits are never reused.
public struct Capabilities: OptionSet, Sendable, Hashable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let hevc444Decode = Capabilities(rawValue: 1 << 0)
    public static let ltr = Capabilities(rawValue: 1 << 1)
    public static let fecRS = Capabilities(rawValue: 1 << 2)
    public static let audioOpus = Capabilities(rawValue: 1 << 3)
    public static let clipboardV1 = Capabilities(rawValue: 1 << 4)
    public static let filesV1 = Capabilities(rawValue: 1 << 5)
    public static let hdr = Capabilities(rawValue: 1 << 6)
    public static let hevc420Decode = Capabilities(rawValue: 1 << 7)
    public static let refinementFrames = Capabilities(rawValue: 1 << 8)
    public static let benchBarcode = Capabilities(rawValue: 1 << 9)
    /// 1.1: the client sends `ReceiverReport`s and the Mac adapts its bitrate to them.
    public static let receiverReports = Capabilities(rawValue: 1 << 10)
    /// 1.1: XOR parity fragments (`VideoFrameFlags.parity`), one per group of data fragments.
    public static let fecXor = Capabilities(rawValue: 1 << 11)
    /// Protocol 1.2: keyboard, pointer, scroll and gesture messages on the input channel (ADR-0013).
    public static let inputV1 = Capabilities(rawValue: 1 << 12)
    /// Protocol 1.2: the cursor is drawn by the phone from `CursorShape`/`CursorPosition` (ADR-0009).
    public static let clientCursor = Capabilities(rawValue: 1 << 13)
}

/// A display mode the client can show at 1:1 pixels (ADR-0007).
public struct DisplayMode: Equatable, Hashable, Sendable {
    public var widthPoints: UInt32
    public var heightPoints: UInt32
    public var scale: UInt8
    public var refreshHz: UInt16

    public init(widthPoints: UInt32, heightPoints: UInt32, scale: UInt8, refreshHz: UInt16) {
        self.widthPoints = widthPoints
        self.heightPoints = heightPoints
        self.scale = scale
        self.refreshHz = refreshHz
    }

    public var widthPixels: UInt32 { widthPoints * UInt32(scale) }
    public var heightPixels: UInt32 { heightPoints * UInt32(scale) }

    /// The four posture modes from docs/video.md §5.
    public static let laptop = DisplayMode(widthPoints: 939, heightPoints: 667, scale: 2, refreshHz: 120)
    public static let flat = DisplayMode(widthPoints: 1335, heightPoints: 939, scale: 2, refreshHz: 120)
    public static let book = DisplayMode(widthPoints: 667, heightPoints: 939, scale: 2, refreshHz: 120)
    public static let cover = DisplayMode(widthPoints: 699, heightPoints: 1017, scale: 2, refreshHz: 120)

    func encode() -> [UInt8] {
        var w = ByteWriter(capacity: 12)
        w.varint(UInt64(widthPoints))
        w.varint(UInt64(heightPoints))
        w.varint(UInt64(scale))
        w.varint(UInt64(refreshHz))
        return w.bytes
    }

    init(encoded: [UInt8]) throws {
        var r = ByteReader(encoded)
        widthPoints = try r.varint().narrowed(to: UInt32.self, field: "widthPoints")
        heightPoints = try r.varint().narrowed(to: UInt32.self, field: "heightPoints")
        scale = try r.varint().narrowed(to: UInt8.self, field: "scale")
        refreshHz = try r.varint().narrowed(to: UInt16.self, field: "refreshHz")
        guard scale >= 1, widthPoints > 0, heightPoints > 0 else { throw WireError.invalidValue("display mode") }
    }
}

/// First message each side sends, encrypted inside Noise msg1 (phone) and msg2 (Mac).
public struct Hello: WireMessage {
    public static let channel = Channel.control
    public static let type = MessageType.hello

    enum Tag {
        static let protoMajor: UInt64 = 1
        static let protoMinor: UInt64 = 2
        static let appVersion: UInt64 = 3
        static let build: UInt64 = 4
        static let capabilities: UInt64 = 5
        static let displayMode: UInt64 = 6
        static let maxFps: UInt64 = 7
        static let deviceName: UInt64 = 8
        static let all: Set<UInt64> = [protoMajor, protoMinor, appVersion, build, capabilities, displayMode, maxFps, deviceName]
    }

    public var protoMajor: UInt16
    public var protoMinor: UInt16
    public var appVersion: String
    public var build: UInt32
    public var capabilities: Capabilities
    public var displayModes: [DisplayMode]
    public var maxFps: UInt16
    public var deviceName: String

    public init(protoMajor: UInt16 = ProtocolVersion.major, protoMinor: UInt16 = ProtocolVersion.minor,
                appVersion: String, build: UInt32, capabilities: Capabilities,
                displayModes: [DisplayMode] = [], maxFps: UInt16 = 120, deviceName: String) {
        self.protoMajor = protoMajor
        self.protoMinor = protoMinor
        self.appVersion = appVersion
        self.build = build
        self.capabilities = capabilities
        self.displayModes = displayModes
        self.maxFps = maxFps
        self.deviceName = deviceName
    }

    public func encodeBody() -> [UInt8] {
        var t = TLVWriter()
        t.uint(Tag.protoMajor, UInt64(protoMajor))
        t.uint(Tag.protoMinor, UInt64(protoMinor))
        t.string(Tag.appVersion, appVersion)
        t.uint(Tag.build, UInt64(build))
        t.uint(Tag.capabilities, capabilities.rawValue)
        for m in displayModes { t.bytes(Tag.displayMode, m.encode()) }
        t.uint(Tag.maxFps, UInt64(maxFps))
        t.string(Tag.deviceName, deviceName)
        return t.bytes
    }

    public init(body: [UInt8]) throws {
        let t = try TLVReader(body, knownTags: Tag.all)
        protoMajor = try t.requiredUInt(Tag.protoMajor).narrowed(to: UInt16.self, field: "protoMajor")
        protoMinor = try t.requiredUInt(Tag.protoMinor).narrowed(to: UInt16.self, field: "protoMinor")
        appVersion = try t.optionalString(Tag.appVersion) ?? ""
        build = try (t.optionalUInt(Tag.build) ?? 0).narrowed(to: UInt32.self, field: "build")
        capabilities = Capabilities(rawValue: try t.optionalUInt(Tag.capabilities) ?? 0)
        displayModes = try t.all(Tag.displayMode).map(DisplayMode.init(encoded:))
        maxFps = try (t.optionalUInt(Tag.maxFps) ?? 60).narrowed(to: UInt16.self, field: "maxFps")
        deviceName = try t.optionalString(Tag.deviceName) ?? ""
    }
}

public enum UpgradeHint: Equatable, Sendable {
    case updateMac
    case updatePhone
    case unknown(UInt64)

    init(raw: UInt64) {
        switch raw {
        case 1: self = .updateMac
        case 2: self = .updatePhone
        default: self = .unknown(raw)
        }
    }

    var raw: UInt64 {
        switch self {
        case .updateMac: 1
        case .updatePhone: 2
        case .unknown(let v): v
        }
    }
}

/// Sent by the Mac after an authenticated handshake when majors differ (ADR-0011).
public struct Incompatible: WireMessage {
    public static let channel = Channel.control
    public static let type = MessageType.incompatible

    public var requiredMajor: UInt16
    public var peerMajor: UInt16
    public var hint: UpgradeHint

    public init(requiredMajor: UInt16, peerMajor: UInt16, hint: UpgradeHint) {
        self.requiredMajor = requiredMajor
        self.peerMajor = peerMajor
        self.hint = hint
    }

    public func encodeBody() -> [UInt8] {
        var t = TLVWriter()
        t.uint(1, UInt64(requiredMajor))
        t.uint(2, UInt64(peerMajor))
        t.uint(3, hint.raw)
        return t.bytes
    }

    public init(body: [UInt8]) throws {
        let t = try TLVReader(body, knownTags: [1, 2, 3])
        requiredMajor = try t.requiredUInt(1).narrowed(to: UInt16.self, field: "requiredMajor")
        peerMajor = try t.requiredUInt(2).narrowed(to: UInt16.self, field: "peerMajor")
        hint = UpgradeHint(raw: try t.requiredUInt(3))
    }
}

/// Result of comparing two `Hello`s.
public enum Negotiation: Equatable, Sendable {
    case compatible(minor: UInt16, capabilities: Capabilities)
    case incompatible(Incompatible)

    /// Called on the Mac (responder) with the phone's Hello.
    public static func negotiate(mac: Hello, phone: Hello) -> Negotiation {
        guard mac.protoMajor == phone.protoMajor else {
            let hint: UpgradeHint = mac.protoMajor < phone.protoMajor ? .updateMac : .updatePhone
            return .incompatible(Incompatible(requiredMajor: max(mac.protoMajor, phone.protoMajor),
                                              peerMajor: min(mac.protoMajor, phone.protoMajor), hint: hint))
        }
        return .compatible(minor: min(mac.protoMinor, phone.protoMinor),
                           capabilities: mac.capabilities.intersection(phone.capabilities))
    }
}
