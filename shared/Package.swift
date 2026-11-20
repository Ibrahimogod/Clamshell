// swift-tools-version: 6.2
// ClamshellKit: code shared by the Mac host, the iOS client and the tools.
// Swift 6 language mode (strict concurrency) is the default for tools-version 6.x.
import PackageDescription

let package = Package(
    name: "ClamshellKit",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .library(name: "ClamshellWire", targets: ["ClamshellWire"]),
        .library(name: "ClamshellSession", targets: ["ClamshellSession"]),
        .library(name: "ClamshellRateControl", targets: ["ClamshellRateControl"]),
        .library(name: "ClamshellBench", targets: ["ClamshellBench"]),
        .library(name: "ClamshellTransport", targets: ["ClamshellTransport"]),
        .library(name: "ClamshellCodec", targets: ["ClamshellCodec"]),
        .library(name: "ClamshellVirtualDisplay", targets: ["ClamshellVirtualDisplay"]),
        .library(name: "ClamshellVideo", targets: ["ClamshellVideo"]),
        .library(name: "ClamshellStream", targets: ["ClamshellStream"]),
        .library(name: "ClamshellKeychain", targets: ["ClamshellKeychain"]),
        .library(name: "ClamshellInput", targets: ["ClamshellInput"]),
        .library(name: "ClamshellFiles", targets: ["ClamshellFiles"]),
    ],
    targets: [
        // Versioned binary protocol: varints, TLVs, inner message header, message types (ADR-0011).
        .target(name: "ClamshellWire"),
        // Noise IKpsk2_25519_ChaChaPoly_SHA256 handshake, transport packets, anti-replay (ADR-0001).
        .target(name: "ClamshellSession", dependencies: ["ClamshellWire"]),
        // Frame policy: latest-only slots, video fragmentation/reassembly, refinement scheduling (ADR-0008).
        .target(name: "ClamshellRateControl", dependencies: ["ClamshellWire"]),
        // Measurement: barcode patch encoding, clock-offset estimation, latency stats (docs/video.md §2).
        .target(name: "ClamshellBench"),
        // UDP endpoint (Network.framework) that carries sealed session packets (P1 LAN in M1).
        .target(name: "ClamshellTransport", dependencies: ["ClamshellWire", "ClamshellSession"]),
        // HEVC bitstream helpers: Annex B / length-prefixed framing, access units, SPS parsing (ADR-0007).
        .target(name: "ClamshellCodec"),
        // Private CGVirtualDisplay declarations (weak-imported) and a Swift wrapper; macOS only (ADR-0006).
        .target(name: "CVirtualDisplay", linkerSettings: [.linkedFramework("CoreGraphics", .when(platforms: [.macOS]))]),
        .target(name: "ClamshellVirtualDisplay", dependencies: ["CVirtualDisplay"]),
        // VideoToolbox HEVC encoder/decoder wrappers and synthetic text test patterns (ADR-0007, ADR-0008).
        .target(name: "ClamshellVideo", dependencies: ["ClamshellCodec"]),
        // The video path end to end, minus capture and display: host frames → encoder → fragments, and
        // fragments → reassembly → decoder → latest-frame slot with keyframe recovery (ADR-0008).
        .target(name: "ClamshellStream", dependencies: ["ClamshellVideo", "ClamshellRateControl", "ClamshellWire", "ClamshellCodec"]),
        // Device-only Keychain storage for long-term keys (identity, dev PSK); never synced (ADR-0014).
        .target(name: "ClamshellKeychain"),
        // Keyboard/trackpad model (ADR-0013): HID→kVK map, phone-side sender + trackpad interpreter, Mac-side
        // receiver (dedupe, modifier reconciliation, key repeat, momentum, watchdog). Pure Swift, no UI.
        .target(name: "ClamshellInput", dependencies: ["ClamshellWire"]),
        // Files of any size and whole folders (protocol 1.9): listing and hashing, the send queue, and the
        // resumable receiver that writes segments at their offsets and checks the hash before saving.
        .target(name: "ClamshellFiles", dependencies: ["ClamshellWire"]),

        .testTarget(name: "ClamshellWireTests", dependencies: ["ClamshellWire"], resources: [.copy("Fixtures")]),
        .testTarget(name: "ClamshellSessionTests", dependencies: ["ClamshellSession", "ClamshellWire"], resources: [.copy("Vectors")]),
        .testTarget(name: "ClamshellRateControlTests", dependencies: ["ClamshellRateControl", "ClamshellWire"]),
        .testTarget(name: "ClamshellBenchTests", dependencies: ["ClamshellBench"]),
        .testTarget(name: "ClamshellTransportTests", dependencies: ["ClamshellTransport", "ClamshellSession", "ClamshellWire"]),
        .testTarget(name: "ClamshellCodecTests", dependencies: ["ClamshellCodec"], resources: [.copy("Samples")]),
        .testTarget(name: "ClamshellVideoTests", dependencies: ["ClamshellVideo", "ClamshellCodec"]),
        .testTarget(name: "ClamshellInputTests", dependencies: ["ClamshellInput", "ClamshellWire"]),
        .testTarget(name: "ClamshellFilesTests", dependencies: ["ClamshellFiles", "ClamshellWire"]),
        .testTarget(name: "ClamshellStreamTests", dependencies: ["ClamshellStream", "ClamshellVideo", "ClamshellWire", "ClamshellRateControl", "ClamshellSession"]),
    ]
)
