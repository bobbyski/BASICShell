// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BASICShell",
    platforms: [.macOS("16.0")],
    dependencies: [
        .package(path: "../BASICCore"),
        .package(path: "../../../frameworks/UILess/Code/TUIKit"),
        .package(url: "https://github.com/bobbyski/VectorTerminalSDK.git", from: "1.5.6")
    ],
    targets: [
        .executableTarget(
            name: "BASICShell",
            dependencies: [
                "BASICCore",
                "TUIKit",
                "VectorTerminalSDK"
            ],
            resources: [
                .copy("Resources/Demos")
            ]
        )
    ]
)
