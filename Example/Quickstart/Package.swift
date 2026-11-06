// swift-tools-version:5.7
import PackageDescription

// Minimal command-line example: one payment against a terminal or the emulator.
//   swift run                    # 127.0.0.1:4444
//   NAPS_PORT=4455 swift run     # another port
let package = Package(
    name: "Quickstart",
    platforms: [.macOS(.v10_15)],
    dependencies: [.package(name: "TKPayNaps", path: "../..")],
    targets: [
        .executableTarget(name: "Quickstart", dependencies: ["TKPayNaps"])
    ]
)
