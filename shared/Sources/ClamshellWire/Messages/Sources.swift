/// Protocol 1.8: what the Mac streams (the whole screen or one window) and how fast.

/// Phone → Mac (1.8, `frameRateCap`): the most frames a second the phone wants now. The battery and heat
/// saver sends 60 or 30; 0 means no cap (the display mode's own rate). The Mac rebuilds the stream at the
/// new rate, so the phone sends it only when the cap changes.
public struct FrameRateRequest: WireMessage {
    public static let channel = Channel.control
    public static let type = MessageType.frameRateRequest

    public var maxFps: UInt16

    public init(maxFps: UInt16) { self.maxFps = maxFps }

    public func encodeBody() -> [UInt8] {
        var t = TLVWriter()
        t.uint(1, UInt64(maxFps))
        return t.bytes
    }

    public init(body: [UInt8]) throws {
        let t = try TLVReader(body, knownTags: [1])
        maxFps = try (t.optionalUInt(1) ?? 0).narrowed(to: UInt16.self, field: "maxFps")
    }

    /// The rate the Mac streams at: the mode's rate, under the phone's cap (if any), never below 15.
    public static func effective(modeHz: Int, cap: UInt16) -> Int {
        guard cap > 0 else { return modeHz }
        return max(15, min(modeHz, Int(cap)))
    }
}

/// Phone → Mac (1.8, `windowStreaming`): send the list of windows that can be streamed on their own.
public struct WindowListRequest: WireMessage {
    public static let channel = Channel.control
    public static let type = MessageType.windowListRequest

    public init() {}
    public func encodeBody() -> [UInt8] { [] }
    public init(body: [UInt8]) throws { _ = try TLVReader(body, knownTags: []) }
}

/// One window the Mac offers (1.8).
public struct StreamableWindow: Equatable, Hashable, Sendable, Identifiable {
    /// The Mac's window number (`CGWindowID`), stable while the window exists.
    public var id: UInt32
    public var app: String
    public var title: String
    /// Its size in the Mac's points.
    public var width: UInt32
    public var height: UInt32

    public init(id: UInt32, app: String, title: String, width: UInt32, height: UInt32) {
        self.id = id; self.app = app; self.title = title; self.width = width; self.height = height
    }

    func encode() -> [UInt8] {
        var t = TLVWriter()
        t.uint(1, UInt64(id))
        t.string(2, app)
        t.string(3, title)
        t.uint(4, UInt64(width))
        t.uint(5, UInt64(height))
        return t.bytes
    }

    init(encoded: [UInt8]) throws {
        let t = try TLVReader(encoded, knownTags: [1, 2, 3, 4, 5])
        id = try t.requiredUInt(1).narrowed(to: UInt32.self, field: "id")
        app = try t.optionalString(2) ?? ""
        title = try t.optionalString(3) ?? ""
        width = try (t.optionalUInt(4) ?? 0).narrowed(to: UInt32.self, field: "width")
        height = try (t.optionalUInt(5) ?? 0).narrowed(to: UInt32.self, field: "height")
        guard id != 0 else { throw WireError.invalidValue("window id 0") }
    }
}

/// Mac → phone (1.8): the answer to `WindowListRequest`, front to back. Sent as a bulk transfer.
public struct WindowList: WireMessage {
    public static let channel = Channel.control
    public static let type = MessageType.windowList
    /// More than this is noise on a phone-sized list.
    public static let maxWindows = 64

    public var windows: [StreamableWindow]

    public init(windows: [StreamableWindow]) { self.windows = Array(windows.prefix(Self.maxWindows)) }

    public func encodeBody() -> [UInt8] {
        var t = TLVWriter()
        for w in windows { t.bytes(1, w.encode()) }
        return t.bytes
    }

    public init(body: [UInt8]) throws {
        let t = try TLVReader(body, knownTags: [1])
        windows = Array(try t.all(1).map(StreamableWindow.init(encoded:)).prefix(Self.maxWindows))
    }
}

/// Phone → Mac (1.8, `windowStreaming`): stream one window (`windowId`), or the whole screen again (0).
/// With `fit`, the Mac also resizes the window to the phone's picture so it shows at 1:1 pixels.
public struct SourceRequest: WireMessage {
    public static let channel = Channel.control
    public static let type = MessageType.sourceRequest

    public var windowId: UInt32
    public var fit: Bool

    public init(windowId: UInt32, fit: Bool = true) { self.windowId = windowId; self.fit = fit }

    public static let wholeScreen = SourceRequest(windowId: 0, fit: false)

    public func encodeBody() -> [UInt8] {
        var t = TLVWriter()
        t.uint(1, UInt64(windowId))
        if fit { t.bool(2, true) }
        return t.bytes
    }

    public init(body: [UInt8]) throws {
        let t = try TLVReader(body, knownTags: [1, 2])
        windowId = try (t.optionalUInt(1) ?? 0).narrowed(to: UInt32.self, field: "windowId")
        fit = (try t.optionalUInt(2) ?? 0) != 0
    }
}

/// Where a window's picture maps on the Mac (1.8): the window's frame in global display points, and the
/// picture's size in points. Pure maths, shared by the Mac's input and cursor code and the tests.
public struct WindowSpace: Sendable, Equatable {
    public var originX: Double, originY: Double
    public var width: Double, height: Double

    public init(originX: Double, originY: Double, width: Double, height: Double) {
        self.originX = originX; self.originY = originY; self.width = width; self.height = height
    }

    /// A point in the picture (0…1 in each axis) → global display points.
    public func global(unitX x: Double, unitY y: Double) -> (x: Double, y: Double) {
        (originX + x * width, originY + y * height)
    }

    /// A global point → 0…1 in the window (outside the window gives values outside 0…1).
    public func unit(globalX x: Double, globalY y: Double) -> (x: Double, y: Double) {
        (width > 0 ? (x - originX) / width : 0, height > 0 ? (y - originY) / height : 0)
    }

    public func contains(globalX x: Double, globalY y: Double) -> Bool {
        x >= originX && y >= originY && x < originX + width && y < originY + height
    }

    /// The window size (points) that shows at 1:1 on a picture of `pictureWidth`×`pictureHeight` points,
    /// kept inside `screenWidth`×`screenHeight` (the window's display, less the menu bar) and no smaller
    /// than 320×240.
    public static func fitted(pictureWidth: Double, pictureHeight: Double, screenWidth: Double, screenHeight: Double) -> (width: Double, height: Double) {
        guard pictureWidth > 0, pictureHeight > 0 else { return (screenWidth, screenHeight) }
        let s = min(1, screenWidth / pictureWidth, screenHeight / pictureHeight)
        return (max(320, (pictureWidth * s).rounded(.down)), max(240, (pictureHeight * s).rounded(.down)))
    }
}
