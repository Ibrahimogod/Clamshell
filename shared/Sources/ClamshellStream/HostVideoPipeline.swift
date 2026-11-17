import ClamshellCodec
import ClamshellRateControl
import ClamshellVideo
import ClamshellWire
import CoreVideo
import Foundation

/// A pixel buffer handed between queues. CVPixelBuffer is a thread-safe, reference-counted CF type;
/// the pipelines never write into a buffer after handing it on.
public struct SharedPixelBuffer: @unchecked Sendable {
    public let buffer: CVPixelBuffer
    public init(_ buffer: CVPixelBuffer) { self.buffer = buffer }
}

/// Mac side of the video path (ADR-0008): damaged frames → encoder → `VideoFormat` + `VideoFragment`
/// payloads, one per datagram. Rules:
/// - **never queue**: at most one frame in the encoder. A frame that arrives while it's busy replaces the
///   pending picture, and the newest picture is encoded as soon as the encoder frees up;
/// - **damage skip**: unchanged screens cost nothing, apart from the scheduled refinement re-encodes;
/// - **refinement**: after 120 ms and 400 ms of stillness the last picture is re-encoded with a lower QP cap;
/// - keyframes only at start, on request, or when the format changes, and at most one per
///   keyframe interval (the floor given at init, raised to 3 × the client's RTT, at most 500 ms): on a lossy
///   path a keyframe is the frame most likely to be lost, and answering every request with another one
///   before the last one could even arrive is how a stream locks up;
/// - bitrate and FEC strength follow `setRate` (the Mac's `BitrateController`);
/// - **keyframe boost**: a keyframe is encoded at `keyframeBitrate` and the target is restored right after.
///   With low-latency rate control the encoder otherwise pays a keyframe back by dropping the frames after it
///   (19–33 at 2670×1734 and 4 Mbit/s on the M5, a 0.25–0.4 s freeze), and the target often sits that low
///   on a static desktop.
/// All state lives on one serial queue; encoder callbacks hop back onto it.
public final class HostVideoPipeline: @unchecked Sendable {
    public struct Stats: Sendable, Equatable {
        public init() {}
        public var framesSent = 0
        public var keyframes = 0
        public var refinements = 0
        public var bytesSent = 0
        public var skippedWhileBusy = 0
        public var encoderDrops = 0
        public var encoderErrors = 0
        /// Refinements the encoder dropped; each is retried after 20 ms (bounded per still period).
        public var refinementRetries = 0
        /// Keyframe requests ignored because a keyframe was already on its way.
        public var duplicateKeyframeRequests = 0
        public var lastEncodeMs = 0.0
        public var lastFrameBytes = 0
        /// Everything handed to the network, FEC parity and format messages included.
        public var wireBytes = 0
        /// Keyframe requests held back by `minKeyframeInterval` (served once it passes).
        public var throttledKeyframes = 0
        public var targetBitrate = 0
        public var parityGroup = 0
        /// Captures not encoded because the network sender was still behind (`maxUnsentFrames`).
        public var skippedSendBacklog = 0
        /// Delay the Mac itself adds between capture and the first datagram (waiting for the sender, pacing),
        /// above its 10 s minimum, same method as the phone's `DelayTracker`. The phone's queuing delay
        /// includes it, so the session subtracts it: rate control must not back off from its own queue.
        public var senderDelayMicros: UInt32 = 0
    }

    /// Payloads for one encoded frame (`VideoFormat` first when it changed or on a keyframe), in send order.
    public typealias Output = @Sendable (_ payloads: [[UInt8]], _ frameId: UInt32, _ isKeyframe: Bool) -> Void

    public let config: EncoderConfig
    public let chroma: ChromaFormat
    private let queue = DispatchQueue(label: "clamshell.host.video", qos: .userInteractive)
    private let encoder: VideoEncoder
    private let converter: PixelConverter?
    private let inputFormat: OSType?
    private let fragmenter: Fragmenter
    private let output: Output
    private let keyframeIntervalFloor: Duration
    private var minKeyframeInterval: Duration
    private var timer: DispatchSourceTimer?

    // Queue-confined state.
    private var scheduler: RefinementScheduler
    private var stats = Stats()
    private var inFlight = false
    /// Frames handed to `output` that the sender hasn't confirmed with `frameSent()` yet.
    private var unsent = 0
    private let maxUnsentFrames: Int?
    private var awaitingSend: [UInt32: UInt64] = [:]        // frameId → capture time, delta frames only
    private var senderDelay = DelayTracker()
    private var pending: (buffer: SharedPixelBuffer, captureNs: UInt64)?
    private var last: (buffer: SharedPixelBuffer, captureNs: UInt64)?
    private var keyframeRequested = true
    private var parityGroup = 0
    private var duplicateWindow: Duration = .milliseconds(150)
    private var capLowered = false
    private let keyframeBitrateCeiling: Int?
    private var boosted = false
    private var frameId: UInt32 = 0
    private var lastKeyframe: (frameId: UInt32, at: ContinuousClock.Instant)?
    private var generation: UInt16 = 0
    private var parameterSets: [[UInt8]] = []
    private var streamChroma: ChromaFormat = .yuv420
    private var sequence: UInt64 = 0
    private var meta: [UInt64: (captureNs: UInt64, refinement: Bool)] = [:]
    private let epoch = ContinuousClock.now

    /// - Parameter chroma: `.yuv444` converts input to 444v before encoding (pair it with `HEVC_Main444_AutoLevel`).
    public init(config: EncoderConfig, chroma: ChromaFormat = .yuv420, refinement: [RefinementScheduler.Stage] = RefinementScheduler.defaultStages,
                datagram: Int = 1200, sessionOverhead: Int, minKeyframeInterval: Duration = .milliseconds(100),
                maxUnsentFrames: Int? = nil, continuing: (frameId: UInt32, generation: UInt16)? = nil,
                keyframeBitrateCeiling: Int? = nil, output: @escaping Output) throws {
        self.config = config
        self.keyframeBitrateCeiling = keyframeBitrateCeiling
        if let c = continuing { frameId = c.frameId; generation = c.generation }
        self.maxUnsentFrames = maxUnsentFrames.map { max(1, $0) }
        self.minKeyframeInterval = minKeyframeInterval
        keyframeIntervalFloor = minKeyframeInterval
        self.chroma = chroma
        encoder = try VideoEncoder(config: config)
        if chroma == .yuv444 {
            converter = try PixelConverter()
            inputFormat = kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange
        } else {
            converter = nil
            inputFormat = nil
        }
        fragmenter = Fragmenter(maxFragmentPayload: Fragmenter.payloadBudget(datagram: datagram, sessionOverhead: sessionOverhead))
        scheduler = RefinementScheduler(stages: refinement)
        self.output = output
        stats.targetBitrate = config.averageBitrate
    }

    /// The last frame id and format generation, so a rebuilt pipeline (a display mode change) can carry
    /// on where this one stopped: the phone then sees newer frames and a new generation, not a restart.
    public var position: (frameId: UInt32, generation: UInt16) { queue.sync { (frameId, generation) } }

    /// Starts the 4 ms housekeeping tick (refinement deadlines, keyframes for a static screen).
    public func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        queue.sync { encoder.flush() }
    }

    /// A captured frame. `damaged == false` means the screen didn't change (SCK idle or empty dirty rects).
    public func submit(_ buffer: SharedPixelBuffer, captureTimeNs: UInt64, damaged: Bool) {
        queue.async { [self] in
            guard damaged || last == nil else { return }
            pending = (buffer, captureTimeNs)
            if inFlight { stats.skippedWhileBusy += 1; return }
            if senderBehind { stats.skippedSendBacklog += 1; return }
            encodePending()
        }
    }

    /// - Parameter lastGoodFrameId: from the client's `KeyframeRequest`. A request that predates a keyframe
    ///   sent within one round trip plus 50 ms (at least 150 ms) is ignored: the client hadn't received it yet.
    ///   A real loss of that keyframe still gets through, because the client repeats its request every 250 ms.
    public func requestKeyframe(lastGoodFrameId: UInt32? = nil) {
        queue.async { [self] in
            if let good = lastGoodFrameId, let k = lastKeyframe, good < k.frameId, ContinuousClock.now - k.at < duplicateWindow {
                stats.duplicateKeyframeRequests += 1
                return
            }
            keyframeRequested = true
            if !keyframeAllowed { stats.throttledKeyframes += 1; return }   // the tick serves it when allowed
            if !busy, pending == nil, let last { pending = last; encodePending() }
        }
    }

    /// Retargets the encoder (takes effect from the next frame) and the FEC group (0 = off).
    /// - Parameter rttMicros: the client's round trip, 0 if unknown.
    public func setRate(bitrate: Int, parityGroup: Int, rttMicros: UInt32 = 0) {
        queue.async { [self] in
            if rttMicros > 0 {
                duplicateWindow = .microseconds(min(1_000_000, max(150_000, Int(rttMicros) + 50_000)))
                minKeyframeInterval = max(keyframeIntervalFloor, min(.milliseconds(500), .microseconds(3 * Int(rttMicros))))
            }
            if bitrate != stats.targetBitrate, encoder.setAverageBitrate(bitrate) { stats.targetBitrate = bitrate }
            self.parityGroup = max(0, parityGroup)
            stats.parityGroup = self.parityGroup
        }
    }

    public var currentStats: Stats { queue.sync { stats } }

    /// The bitrate a keyframe is encoded at: 4 × the target, and at least 7.5 bits per pixel per second
    /// (enough on the M5 for a keyframe to fit without dropping the frames after it: 25 Mbit/s at 2670×1734
    /// 4:4:4, 12 Mbit/s at 1600×1038 4:2:0), never above `ceiling` and never below the target.
    public static func keyframeBitrate(target: Int, width: Int, height: Int, ceiling: Int) -> Int {
        let wanted = max(4 * target, Int(7.5 * Double(width * height)))
        return max(target, min(ceiling, wanted))
    }

    /// A keyframe may go out now: none sent yet, or the last one is `minKeyframeInterval` old.
    private var keyframeAllowed: Bool {
        guard let k = lastKeyframe else { return true }
        return ContinuousClock.now - k.at >= minKeyframeInterval
    }

    /// Chroma of the stream actually being sent (from the SPS), once the first frame is out.
    public var currentChroma: ChromaFormat { queue.sync { streamChroma } }

    static func chroma(of sets: [[UInt8]]) -> ChromaFormat? {
        guard let sps = sets.first(where: { HEVCNALType.type(of: $0) == HEVCNALType.sps }),
              let info = try? HEVCSPSInfo(sps: sps) else { return nil }
        switch info.chromaFormatIdc {
        case 1: return .yuv420
        case 2: return .yuv422
        case 3: return .yuv444
        default: return nil
        }
    }

    // MARK: queue

    private func encodePending() {
        guard let p = pending else { return }
        pending = nil
        if capLowered { encoder.setMaxFrameQP(nil); capLowered = false }
        scheduler.contentChanged(at: .now)
        last = p
        submitToEncoder(p.buffer, captureNs: p.captureNs, refinement: false)
    }

    /// Backpressure from the network. With pacing, a keyframe can take several frame intervals to leave;
    /// frames encoded meanwhile would have to be dropped after encoding, and a dropped P-frame breaks the
    /// reference chain (decoder errors, then a keyframe storm). Not encoding them is harmless: the newest
    /// capture waits in `pending` and goes out as soon as the sender catches up.
    private var senderBehind: Bool { maxUnsentFrames.map { unsent >= $0 } ?? false }
    private var busy: Bool { inFlight || senderBehind }

    /// The sender is putting the first datagram of `frameId` on the wire.
    public func sendStarted(frameId: UInt32, nowNs: UInt64) {
        queue.async { [self] in
            guard let capture = awaitingSend.removeValue(forKey: frameId) else { return }
            senderDelay.add(arrivalNs: nowNs, captureNs: capture)
            stats.senderDelayMicros = senderDelay.queuingDelayMicros
        }
    }

    /// The session's sender finished sending one frame from `output` (only with `maxUnsentFrames`).
    public func frameSent() {
        queue.async { [self] in
            unsent = max(0, unsent - 1)
            if !busy, pending != nil { encodePending() }
        }
    }

    private func tick() {
        guard !busy else { return }
        if pending != nil { encodePending(); return }
        if keyframeRequested, keyframeAllowed, let last { pending = last; encodePending(); return }
        guard let last, case .refine(let qp)? = scheduler.poll(now: .now) else { return }
        capLowered = encoder.setMaxFrameQP(qp)
        submitToEncoder(last.buffer, captureNs: last.captureNs, refinement: true)
    }

    private func submitToEncoder(_ buffer: SharedPixelBuffer, captureNs: UInt64, refinement: Bool) {
        sequence += 1
        let tag = sequence
        meta[tag] = (captureNs, refinement)
        var input = buffer.buffer
        if let converter, let inputFormat, CVPixelBufferGetPixelFormatType(input) != inputFormat {
            do { input = try converter.convert(input, to: inputFormat) } catch {
                stats.encoderErrors += 1
                return
            }
        }
        inFlight = true
        let key = keyframeRequested && keyframeAllowed
        if key { keyframeRequested = false }
        if key, let ceiling = keyframeBitrateCeiling {
            let b = Self.keyframeBitrate(target: stats.targetBitrate, width: config.width, height: config.height, ceiling: ceiling)
            if b > stats.targetBitrate, encoder.setAverageBitrate(b) { boosted = true }
        }
        // Encoder timestamps must strictly increase, also for re-encodes of the same picture.
        let elapsed = (ContinuousClock.now - epoch).components
        let pts = UInt64(elapsed.seconds) * 1_000_000_000 + UInt64(elapsed.attoseconds / 1_000_000_000) + tag
        encoder.encode(input, ptsNs: pts, forceKeyframe: key, tag: tag) { [weak self] result in
            guard let self else { return }
            self.queue.async { self.encoded(result, tag: tag, wasKeyRequest: key) }
        }
    }

    private func encoded(_ result: Result<EncodedFrame, VideoError>, tag: UInt64, wasKeyRequest: Bool) {
        inFlight = false
        if boosted { boosted = false; encoder.setAverageBitrate(stats.targetBitrate) }
        let m = meta.removeValue(forKey: tag)
        switch result {
        case .failure(let error):
            if case .noData = error { stats.encoderDrops += 1 } else { stats.encoderErrors += 1 }
            if wasKeyRequest { keyframeRequested = true }
            // A dropped refinement would leave static text soft until the next change: retry it.
            if m?.refinement == true, pending == nil {
                stats.refinementRetries += 1
                scheduler.refinementDropped(at: .now)
            }
        case .success(let frame):
            emit(frame, captureNs: m?.captureNs ?? 0, refinement: m?.refinement ?? false)
        }
        if pending != nil, !busy { encodePending() }
    }

    private func emit(_ frame: EncodedFrame, captureNs: UInt64, refinement: Bool) {
        var payloads: [[UInt8]] = []
        if frame.parameterSets != parameterSets {
            parameterSets = frame.parameterSets
            generation &+= 1
            // The SPS is the truth: VideoToolbox silently falls back to 4:2:0 for some profile/input pairs.
            streamChroma = Self.chroma(of: parameterSets) ?? chroma
        }
        if frame.isKeyframe {
            let format = VideoFormat(generation: generation, codec: .hevc, widthPixels: UInt32(config.width), heightPixels: UInt32(config.height),
                                     chroma: streamChroma, fullRange: false, parameterSets: parameterSets)
            payloads.append(format.message.encoded)
        }
        frameId &+= 1
        var flags: VideoFrameFlags = []
        if frame.isKeyframe { flags.insert(.keyframe) }
        if refinement { flags.insert(.refinement) }
        // Keyframes get twice the protection: losing one costs a whole keyframe round trip.
        let group = parityGroup == 0 ? 0 : frame.isKeyframe ? max(2, parityGroup / 2) : parityGroup
        do {
            for f in try fragmenter.fragments(frameId: frameId, flags: flags, formatGeneration: generation, captureTimeNs: captureNs,
                                              data: frame.data, parityGroup: group) {
                payloads.append(f.message.encoded)
            }
        } catch {
            stats.encoderErrors += 1
            keyframeRequested = true
            return
        }
        stats.framesSent += 1
        if frame.isKeyframe { stats.keyframes += 1; lastKeyframe = (frameId, .now) }
        if refinement { stats.refinements += 1 }
        stats.bytesSent += frame.data.count
        stats.lastFrameBytes = frame.data.count
        stats.wireBytes += payloads.reduce(0) { $0 + $1.count }
        let c = frame.encodeLatency.components
        stats.lastEncodeMs = Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
        if maxUnsentFrames != nil {
            unsent += 1
            if !frame.isKeyframe, !refinement {               // the same frames the phone's tracker uses
                awaitingSend[frameId] = captureNs
                if awaitingSend.count > 64, let oldest = awaitingSend.keys.min() { awaitingSend.removeValue(forKey: oldest) }
            }
        }
        output(payloads, frameId, frame.isKeyframe)
    }
}
