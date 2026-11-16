// swift-tools-version: 6.2
// Developer tools: day-1 probes (ADR-0006/0007 evidence) and the latency/upload bench (docs/video.md §2).
import PackageDescription

let package = Package(
    name: "ClamshellTools",
    platforms: [.macOS("26.0")],
    dependencies: [.package(path: "../shared")],
    targets: [
        .executableTarget(name: "clamshell-probe", dependencies: [
            .product(name: "ClamshellVideo", package: "shared"),
            .product(name: "ClamshellCodec", package: "shared"),
            .product(name: "ClamshellVirtualDisplay", package: "shared"),
            .product(name: "ClamshellSession", package: "shared"),
            .product(name: "ClamshellWire", package: "shared"),
            .product(name: "ClamshellRateControl", package: "shared"),
            .product(name: "ClamshellBench", package: "shared"),
            .product(name: "ClamshellStream", package: "shared"),
            .product(name: "ClamshellTransport", package: "shared"),
        ]),
        // Userspace UDP relay with delay, jitter, loss, bottleneck and outages: remote paths on one Mac.
        .executableTarget(name: "clamshell-netsim"),
        .executableTarget(name: "clamshell-bench", dependencies: [
            .product(name: "ClamshellBench", package: "shared"),
            .product(name: "ClamshellStream", package: "shared"),
            .product(name: "ClamshellVideo", package: "shared"),
            .product(name: "ClamshellWire", package: "shared"),
            .product(name: "ClamshellSession", package: "shared"),
        ]),
    ]
)
