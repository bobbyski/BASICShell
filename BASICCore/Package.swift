// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BASICCore",
    // macOS 16 is TUIKit's floor, inherited when BASICCore took the dependency
    // (TUIKIT_PLAN.md §5). Free today: BASICShell and BASICStudio are both
    // already .macOS("16.0"). It does close the door on a macOS 14 consumer.
    platforms: [.macOS("16.0")],
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
        .package(path: "../../../frameworks/RichSwift"),
        // The interactive layer. Unlike RichSwift this is not free: TUIKit's
        // @Bound macro pulls in swift-syntax, which SwiftPM rebuilds for the
        // release configuration. Measured before and after — see the commit.
        .package(path: "../../../frameworks/UILess/Code/TUIKit")
    ],
    targets: [
        .target(
            name: "BASICCore",
            dependencies: [
                .product(name: "RichSwift", package: "RichSwift"),
                .product(name: "TUIKit", package: "TUIKit"),
            ]
        ),
        .testTarget(name: "BASICCoreTests", dependencies: ["BASICCore"])
    ]
)
