// swift-tools-version: 6.0

import Foundation
import PackageDescription

// VectorTerminalSDK has to be declared the same way TUIKit declares it, or
// SwiftPM sees the GitHub URL and TUIKit's local checkout as two packages
// claiming one identity ("Conflicting identity for vectorterminalsdk", which
// SwiftPM says it will escalate to an error). Same env override as TUIKit so a
// machine with a different layout — or CI — resolves both to the same place.
let vectorTerminalSDKPath = ProcessInfo.processInfo.environment["VECTORTERMINALSDK_PATH"]
    ?? "/Users/bobby/AIResearch/GraphicalTerminal/Code/VectorTerminalSDK"

let package = Package(
    name: "BASICShell",
    platforms: [.macOS("16.0")],
    dependencies: [
        .package(path: "../BASICCore"),
        .package(path: "../../../frameworks/UILess/Code/TUIKit"),
        .package(path: vectorTerminalSDKPath)
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
