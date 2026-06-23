// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BASICShell",
    platforms: [.macOS("16.0")],
    dependencies: [
        .package(path: "../BASICCore"),
        .package(url: "https://github.com/migueldeicaza/TermKit", branch: "main"),
        .package(url: "https://github.com/bobbyski/VectorTerminalSDK.git", from: "1.1.2")
    ],
    targets: [
        .executableTarget(
            name: "BASICShell",
            dependencies: [
                "BASICCore",
                "VectorTerminalSDK"
            ],
            resources: [
                .copy("Resources/Demos")
            ]
        ),
        .executableTarget(
            name: "BASICEdit",
            dependencies: [
                "TermKit"
            ]
        )
    ]
)
