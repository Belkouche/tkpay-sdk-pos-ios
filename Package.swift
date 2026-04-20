// swift-tools-version:5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "TKPayNaps",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15)
    ],
    products: [
        .library(
            name: "TKPayNaps",
            targets: ["TKPayNaps"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "TKPayNaps",
            dependencies: [],
            path: "Sources/TKPayNaps"
        ),
        .testTarget(
            name: "TKPayNapsTests",
            dependencies: ["TKPayNaps"],
            path: "Tests/TKPayNapsTests"
        ),
    ]
)
