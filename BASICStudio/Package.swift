// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BASICStudio",
    platforms: [.macOS("16.0")],
    dependencies: [
        .package(path: "../BASICCore"),
        .package(path: "../DocumentArchive"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.1"),
        .package(url: "https://github.com/bobbyski/SwiftTerm.git", from: "1.5.6"),
        .package(url: "https://github.com/bobbyski/VectorTerminalSDK.git", from: "1.5.6")
    ],
    targets: [
        .executableTarget(
            name: "BASICStudio",
            dependencies: [
                "BASICCore",
                "DocumentArchive",
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                "SwiftTerm",
                "VectorTerminalSDK"
            ],
            exclude: [
                "Resources/AppIcon.iconset"
            ],
            resources: [
                .copy("Resources/Demos"),
                .copy("Resources/UserDocs.zip"),
                .copy("Resources/Fonts"),
                .copy("Resources/Assets"),
                .process("Resources/Assets.xcassets")
            ]
        )
    ]
)
