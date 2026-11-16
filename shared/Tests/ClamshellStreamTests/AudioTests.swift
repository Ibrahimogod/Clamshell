import AVFAudio
import ClamshellStream
import ClamshellWire
import Foundation
import Testing

@Suite("Audio (M5)")
struct AudioTests {
    /// 1 s of a 440 Hz tone in odd-sized chunks (SCK hands over ~1024 frames) comes out as 20 ms Opus
    /// packets with consecutive seqs and timestamps 20 ms apart, and decodes back to sound.
    @Test func toneRoundTrip() throws {
        let enc = try OpusEncoder()
        let dec = try OpusDecoder()
        var packets: [AudioPacket] = []
        var phase = 0.0
        var t: UInt64 = 5_000_000_000
        for _ in 0..<47 {                                    // 47 × 1024 ≈ 1.003 s
            var chunk = [Float](repeating: 0, count: 1024)
            for i in chunk.indices { chunk[i] = Float(sin(phase) * 0.5); phase += 2 * .pi * 440 / 48_000 }
            packets += enc.encode(planar: [chunk, chunk], captureNs: t)
            t += UInt64(1024.0 / 48_000 * 1e9)
        }
        #expect(packets.count >= 48 && packets.count <= 50)
        for (a, b) in zip(packets, packets.dropFirst()) {
            #expect(b.seq == a.seq + 1)
            let gap = Double(b.captureNs - a.captureNs) / 1e6
            #expect(abs(gap - 20) < 0.01)
        }
        #expect(packets.allSatisfy { $0.data.count < 600 })   // ~96 kbit/s
        var energy = 0.0, frames = 0
        for p in packets {
            let back = try AudioPacket(p.message)
            guard let pcm = dec.decode(back.data), let ch = pcm.floatChannelData else { Issue.record("decode failed"); continue }
            frames += Int(pcm.frameLength)
            for i in 0..<Int(pcm.frameLength) { energy += Double(ch[0][i] * ch[0][i]) }
        }
        #expect(frames >= 48 * 960)
        #expect(energy / Double(frames) > 0.05)              // a 0.5 sine has mean square 0.125
    }

    @Test func jitterNeverLetsLatencyGrow() {
        var j = AudioJitterPolicy()
        let r1 = j.shouldPlay(queuedMs: 20)
        #expect(r1 == false)          // waits for 40 ms first
        let r2 = j.admit(seq: 0, queuedMs: 20)
        #expect(r2 == .play)
        let r3 = j.shouldPlay(queuedMs: 40)
        #expect(r3)
        let r4 = j.admit(seq: 1, queuedMs: 60)
        #expect(r4 == .play)
        let r5 = j.admit(seq: 2, queuedMs: 130)
        #expect(r5 == .drop)      // over 120 ms queued: drop, don't fall behind
        let r6 = j.admit(seq: 2, queuedMs: 20)
        #expect(r6 == .drop)       // duplicate
        let r7 = j.admit(seq: 1, queuedMs: 20)
        #expect(r7 == .drop)       // stale
        let r8 = j.admit(seq: 6, queuedMs: 20)
        #expect(r8 == .play)
        #expect(j.lost == 3)
        #expect(j.dropped == 3)
        let r9 = j.shouldPlay(queuedMs: 0)
        #expect(r9 == false)           // underrun: wait to refill
        let r10 = j.shouldPlay(queuedMs: 30)
        #expect(r10 == false)
        let r11 = j.shouldPlay(queuedMs: 45)
        #expect(r11)
    }

    @Test func macRestartIsANewStream() {
        var j = AudioJitterPolicy()
        for s in UInt32(100)...UInt32(200) { _ = j.admit(seq: s, queuedMs: 20) }
        let back = j.admit(seq: 0, queuedMs: 20)              // the Mac rebuilt the stream: seq starts over
        #expect(back == .play)
        let next = j.admit(seq: 1, queuedMs: 20)
        #expect(next == .play)
        #expect(j.dropped == 0)
    }

    @Test func rejectsBadPackets() {
        #expect(throws: (any Error).self) { try AudioPacket(AudioPacket(seq: 1, captureNs: 0, data: []).message) }
        #expect(throws: (any Error).self) { try AudioPacket(AudioPacket(seq: 1, captureNs: 0, data: [UInt8](repeating: 1, count: 2000)).message) }
    }
}
