import ClamshellRateControl
import ClamshellVideo
import ClamshellWire
import CoreVideo
import Darwin
import Foundation

/// A decoded frame ready to present. The renderer takes the newest one each display refresh.
public struct DecodedPicture: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let frameId: UInt32
    public let flags: VideoFrameFlags
    /// Mac `ContinuousClock` nanoseconds at capture (map with `ClockSync` for latency).
    public let captureTimeNs: UInt64
    public let receivedAt: ContinuousClock.Instant
    public let decodedAt: ContinuousClock.Instant
}

/// Phone side of the video path (ADR-0008): fragments → `Reassembler` → `VideoDecoder` → `LatestSlot`.
/// - never queue: only the newest decoded picture is kept, and older incomplete frames are discarded;
/// - a broken reference chain (gap, expired frame, decoder error) → `KeyframeRequest`, and P-frames are
///   ignored until the keyframe arrives. Requests repeat every 250 ms until one does;
/// - every 100 ms a `ReceiverReport` (loss, queuing delay) for the Mac's rate controller, when the Mac
///   understands one. Queuing delay is ping RTT above its 10 s minimum (`setRoundTrip`). Not frame
///   timing: a frame's capture-to-arrival time includes waiting on the Mac (sender backlog, pacing a big
///   frame), and the Mac must not back off from its own queue. A pong never waits behind video.
public final class ClientVideoPipeline: @unchecked Sendable {
    public struct Stats: Sendable, Equatable {
        public init() {}
        public var framesDecoded = 0
        public var keyframes = 0
        public var refinements = 0
        public var framesLost = 0
        public var skippedAwaitingKeyframe = 0
        public var decoderErrors = 0
        public var keyframeRequests = 0
        public var bytesReceived = 0
        public var lastDecodeMs = 0.0
        public var chroma: ChromaFormat = .yuv420
        public var hardwareDecoder: Bool?
    }

    public let latest = LatestSlot<DecodedPicture>()
    private let queue = DispatchQueue(label: "clamshell.client.video", qos: .userInteractive)
    private let requestKeyframe: @Sendable (KeyframeRequest) -> Void
    private let requireHardware: Bool
    private let sendReport: (@Sendable (ReceiverReport) -> Void)?
    private var timer: DispatchSourceTimer?

    // Queue-confined state.
    private var reassembler = Reassembler()
    private var formats: [UInt16: VideoFormat] = [:]
    private var decoder: (generation: UInt16, decoder: VideoDecoder)?
    private var awaitingKeyframe = true
    private var lastRequest: ContinuousClock.Instant?
    private var lastGood: UInt32 = 0
    private var stats = Stats()
    private var delay = DelayTracker()
    private var reported = Reassembler.Counters()
    private var lastReportNs: UInt64 = 0
    private var rttMicros: UInt32 = 0

    public init(requireHardware: Bool = false, requestKeyframe: @escaping @Sendable (KeyframeRequest) -> Void,
                sendReport: (@Sendable (ReceiverReport) -> Void)? = nil) {
        self.requireHardware = requireHardware
        self.requestKeyframe = requestKeyframe
        self.sendReport = sendReport
    }

    static func nowNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    /// Starts the 20 ms housekeeping tick (expire stalled frames, repeat keyframe requests).
    public func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(5))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        queue.async { [self] in askForKeyframe(.sessionStart, force: true) }
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    public var currentStats: Stats { queue.sync { stats } }

    /// The latest ping round trip, passed on in the next `ReceiverReport`.
    private var smoothedRtt: Double?

    public func setRoundTrip(nanoseconds: Int64) {
        // Smoothed like TCP's SRTT (1/8 gain): one ping stuck behind session start-up shouldn't set the
        // Mac's keyframe throttle to its 500 ms cap.
        queue.async { [self] in
            let sample = Double(max(0, nanoseconds)) / 1000
            let now = Self.nowNs()
            delay.add(arrivalNs: now, captureNs: now &- UInt64(max(0, nanoseconds)))
            smoothedRtt = smoothedRtt.map { $0 * 0.875 + sample * 0.125 } ?? sample
            rttMicros = UInt32(clamping: Int(smoothedRtt ?? 0))
        }
    }

    /// Feed every inner message received on the video channel.
    public func handle(_ messages: [InnerMessage]) {
        let now = ContinuousClock.now
        queue.async { [self] in
            for m in messages {
                switch m.type {
                case .videoFormat:
                    if let f = try? VideoFormat(m) { formats[f.generation] = f }
                case .videoFragment:
                    guard let f = try? VideoFragment(m) else { continue }
                    stats.bytesReceived += f.payload.count
                    for e in reassembler.add(f, now: now) { handle(e, receivedAt: now) }
                default:
                    continue
                }
            }
        }
    }

    // MARK: queue

    private func tick() {
        let now = ContinuousClock.now
        for e in reassembler.expire(now: now) { handle(e, receivedAt: now) }
        if awaitingKeyframe { askForKeyframe(.frameLost, force: false) }
        let t = Self.nowNs()
        if sendReport != nil, t >= lastReportNs + 100_000_000 { report(at: t) }
    }

    private func report(at t: UInt64) {
        let c = reassembler.counters, r = reported
        let interval = lastReportNs == 0 ? 100_000 : (t - lastReportNs) / 1000
        lastReportNs = t
        reported = c
        let highest = reassembler.highestFrameId
        sendReport?(ReceiverReport(intervalMicros: UInt32(clamping: interval), bytesReceived: UInt32(clamping: c.bytesReceived - r.bytesReceived),
                                   framesCompleted: UInt16(clamping: c.framesCompleted - r.framesCompleted),
                                   framesLost: UInt16(clamping: c.framesLost - r.framesLost),
                                   fragmentsReceived: UInt32(clamping: c.fragmentsReceived - r.fragmentsReceived),
                                   fragmentsExpected: UInt32(clamping: c.fragmentsExpected - r.fragmentsExpected),
                                   queuingDelayMicros: delay.queuingDelayMicros, highestFrameId: highest,
                                   fecRecovered: UInt16(clamping: c.fecRecovered - r.fecRecovered), rttMicros: rttMicros))
    }

    private func askForKeyframe(_ reason: KeyframeReason, force: Bool) {
        let now = ContinuousClock.now
        if !force, let last = lastRequest, now - last < .milliseconds(250) { return }
        lastRequest = now
        awaitingKeyframe = true
        stats.keyframeRequests += 1
        requestKeyframe(KeyframeRequest(reason: reason, lastGoodFrameId: lastGood))
    }

    private func handle(_ event: Reassembler.Event, receivedAt: ContinuousClock.Instant) {
        switch event {
        case .dropped:
            stats.framesLost += 1
            if !awaitingKeyframe { askForKeyframe(.frameLost, force: true) }
        case .complete(let frame, let gap):
            let isKey = frame.flags.contains(.keyframe)
            if gap && !isKey && !awaitingKeyframe { askForKeyframe(.frameLost, force: true) }
            if awaitingKeyframe && !isKey {
                stats.skippedAwaitingKeyframe += 1
                return
            }
            decode(frame, receivedAt: receivedAt)
        }
    }

    private func decode(_ frame: Reassembler.Frame, receivedAt: ContinuousClock.Instant) {
        let isKey = frame.flags.contains(.keyframe)
        if decoder?.generation != frame.formatGeneration || isKey && decoder == nil {
            guard isKey, let format = formats[frame.formatGeneration] else {
                askForKeyframe(.formatChanged, force: !awaitingKeyframe)
                return
            }
            do {
                let fullRange = format.fullRange
                let pixelFormat: OSType = switch format.chroma {
                case .yuv444: fullRange ? kCVPixelFormatType_444YpCbCr8BiPlanarFullRange : kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange
                case .yuv422: fullRange ? kCVPixelFormatType_422YpCbCr8BiPlanarFullRange : kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange
                default: fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                }
                let d = try VideoDecoder(parameterSets: format.parameterSets, outputPixelFormat: pixelFormat, requireHardware: requireHardware)
                decoder = (frame.formatGeneration, d)
                stats.chroma = format.chroma
                stats.hardwareDecoder = d.usingHardware
            } catch {
                stats.decoderErrors += 1
                askForKeyframe(.decoderError, force: true)
                return
            }
        }
        guard let d = decoder?.decoder else { return }
        if isKey {
            awaitingKeyframe = false
            reassembler.resetChain()
        }
        let id = frame.frameId, flags = frame.flags, capture = frame.captureTimeNs
        d.decode(frame.data, ptsNs: UInt64(id)) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let pic):
                let picture = DecodedPicture(pixelBuffer: pic.pixelBuffer, frameId: id, flags: flags, captureTimeNs: capture,
                                             receivedAt: receivedAt, decodedAt: .now)
                _ = self.latest.put(picture)
                self.queue.async {
                    self.lastGood = id
                    self.stats.framesDecoded += 1
                    if flags.contains(.keyframe) { self.stats.keyframes += 1 }
                    if flags.contains(.refinement) { self.stats.refinements += 1 }
                    let c = pic.decodeLatency.components
                    self.stats.lastDecodeMs = Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
                }
            case .failure:
                self.queue.async {
                    self.stats.decoderErrors += 1
                    self.askForKeyframe(.decoderError, force: true)
                }
            }
        }
    }
}
