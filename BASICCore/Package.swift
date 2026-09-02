// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BASICCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BASICCore", targets: ["BASICCore"])
    ],
    dependencies: [
        // RichSwift renders rich *content* — markdown, tables, panels — and is
        // what the Rich* pseudo classes are made of. Chosen as the first piece
        // of TUIKIT_PLAN.md because it costs BASICCore nothing: RichSwift has
        // no dependencies of its own and declares no platform floor, so it adds
        // neither swift-syntax nor a macOS bump. TUIKit, which does both, comes
        // later and with its own measurement.
        .package(path: "../../../frameworks/RichSwift")
    ],
    targets: [
        .target(
            name: "BASICCore",
            dependencies: [.product(name: "RichSwift", package: "RichSwift")]
        ),
        .testTarget(name: "BASICCoreTests", dependencies: ["BASICCore"])
    ]
)
