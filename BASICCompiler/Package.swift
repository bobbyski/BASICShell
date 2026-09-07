// swift-tools-version: 6.1

import Foundation
import PackageDescription

// VectorTerminalSDK is declared the way BASICShell and TUIKit declare it —
// a local path with the same env override — so SwiftPM sees one package.
let vectorTerminalSDKPath = ProcessInfo.processInfo.environment["VECTORTERMINALSDK_PATH"]
    ?? "/Users/bobby/AIResearch/GraphicalTerminal/Code/VectorTerminalSDK"

// BASICCompiler — `basicc`, a BASIC compiler that builds LLVM modules and
// links against Swift libraries. A sibling of BASICShell and BASICStudio;
// see Documents/BASIC_COMPILER.md for the plan.
//
//   basicc                    the CLI driver
//   basictest                 the conformance runner: compiled vs expected
//                             vs the interpreter
//   BASICCompilerKit          the shared dialect protocol, driver, BIR,
//                             diagnostics — owns no language knowledge
//   BASICDialectTraditional   the default dialect (Rev 1)
//   BASICDialectSwift         the Swift-substrate dialect (Rev 2), where a
//                             BASIC CLASS is a real Swift class
//   BASICRT                   the runtime library, in Swift, linked into
//                             every compiled program
//   BASICBuildPlugin          swift build compiles .bas files in a C target
//
// The only dependency is BASICSyntax — the interpreter's own front end,
// published by the BASICCore package. Nothing is fetched from the network.
let package = Package(
    name: "BASICCompiler",
    platforms: [.macOS("16.0")],
    products: [
        .executable(name: "basicc", targets: ["basicc"]),
        .executable(name: "basictest", targets: ["basictest"]),
        // The target is `BASICLintCLI`, not `basiclint`: a target whose
        // name differs from the `BASICLint` library only by case collides
        // with it on a case-insensitive filesystem. The product keeps the
        // name the command is spelled with.
        .executable(name: "basiclint", targets: ["BASICLintCLI"]),
        .library(name: "BASICCompilerKit", targets: ["BASICCompilerKit"]),
        .library(name: "BASICDialectTraditional", targets: ["BASICDialectTraditional"]),
        // Rev 2. A peer of the traditional dialect, never a replacement:
        // both ship, both are maintained, and `traditional` stays default.
        .library(name: "BASICDialectSwift", targets: ["BASICDialectSwift"]),
        .library(name: "BASICRT", type: .static, targets: ["BASICRT"]),
        // The host half of the runtime: VTG graphics (and, later, TUIKit and
        // events). Built by SwiftPM because it links the host SDKs; linked
        // into a program when present, else stubbed.
        .library(name: "BASICRTHost", type: .static, targets: ["BASICRTHost"]),
        // The stand-in for the host half: a program built without the host
        // SDKs (a SwiftPM package using the plugin) links this instead.
        .library(name: "BASICRTHostStubs", type: .static, targets: ["BASICRTHostStubs"]),
        // Compile .bas sources inside any package's C-family target
        // (see Plugins/BASICBuildPlugin for the how and why).
        .plugin(name: "BASICBuildPlugin", targets: ["BASICBuildPlugin"]),
    ],
    dependencies: [
        .package(path: "../BASICCore"),
        .package(path: vectorTerminalSDKPath),
    ],
    targets: [
        .target(
            name: "BASICCompilerKit",
            dependencies: [.product(name: "BASICSyntax", package: "BASICCore")]
        ),
        .target(name: "BASICDialectTraditional", dependencies: ["BASICCompilerKit"]),
        .target(name: "BASICDialectSwift", dependencies: ["BASICCompilerKit"]),
        .target(name: "BASICRT"),
        .target(name: "BASICRTHost", dependencies: ["BASICRT", .product(name: "VectorTerminalSDK", package: "VectorTerminalSDK"), .product(name: "BASICCore", package: "BASICCore")]),
        .target(name: "BASICRTHostStubs", dependencies: ["BASICRT"]),
        .executableTarget(
            name: "basicc",
            dependencies: ["BASICCompilerKit", "BASICDialectTraditional", "BASICDialectSwift"]
        ),
        .executableTarget(
            name: "BASICLintCLI",
            dependencies: [.product(name: "BASICLint", package: "BASICCore")],
            path: "Sources/basiclint"
        ),
        .plugin(name: "BASICBuildPlugin", capability: .buildTool(), dependencies: ["basicc"]),
        .executableTarget(
            name: "basictest",
            dependencies: ["BASICCompilerKit", "BASICDialectTraditional"]
        ),
        .testTarget(
            name: "BASICCompilerKitTests",
            dependencies: ["BASICCompilerKit", "BASICDialectTraditional", "BASICDialectSwift"]
        ),
    ]
)
