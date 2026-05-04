// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BASICShell",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../BASICCore")
    ],
    targets: [
        .executableTarget(
            name: "BASICShell",
            dependencies: ["BASICCore"]
        )
    ]
)
