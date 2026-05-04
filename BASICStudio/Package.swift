// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BASICStudio",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../BASICCore"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.1"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", branch: "main")
    ],
    targets: [
        .executableTarget(
            name: "BASICStudio",
            dependencies: [
                "BASICCore",
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                "SwiftTerm"
            ]
        )
    ]
)
