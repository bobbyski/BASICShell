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
        .package(url: "https://github.com/bobbyski/VectorTerminalSDK.git", from: "1.5.6"),
        // The second shell (`--activeui`, Documents/ACTIVEUI_TRANSITION.md).
        // A sibling checkout, as FreebirdStudio took it before it moved to
        // prebuilt frameworks.
        .package(path: "../../../../AIResearch/ActiveUI/Code/ActiveUI"),
        .package(path: "../../../../AIResearch/ActiveUI/Code/ActiveUIMarkdown")
    ],
    targets: [
        .executableTarget(
            name: "BASICStudio",
            dependencies: [
                "BASICCore",
                "DocumentArchive",
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                "SwiftTerm",
                "VectorTerminalSDK",
                .product(name: "ActiveUI", package: "ActiveUI"),
                .product(name: "ActiveUIMarkdown", package: "ActiveUIMarkdown")
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
        ),
        // Headless: the model, the projections, the pages. No window.
        .testTarget(
            name: "BASICStudioTests",
            dependencies: ["BASICStudio"]
        )
    ]
)
