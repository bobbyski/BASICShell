// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BASICCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BASICCore", targets: ["BASICCore"])
    ],
    targets: [
        .target(name: "BASICCore"),
        .testTarget(name: "BASICCoreTests", dependencies: ["BASICCore"])
    ]
)
