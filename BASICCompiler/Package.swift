// swift-tools-version: 6.1

import PackageDescription

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
        .library(name: "BASICCompilerKit", targets: ["BASICCompilerKit"]),
        .library(name: "BASICDialectTraditional", targets: ["BASICDialectTraditional"]),
        .library(name: "BASICRT", type: .static, targets: ["BASICRT"]),
        // Compile .bas sources inside any package's C-family target
        // (see Plugins/BASICBuildPlugin for the how and why).
        .plugin(name: "BASICBuildPlugin", targets: ["BASICBuildPlugin"]),
    ],
    dependencies: [
        .package(path: "../BASICCore"),
    ],
    targets: [
        .target(
            name: "BASICCompilerKit",
            dependencies: [.product(name: "BASICSyntax", package: "BASICCore")]
        ),
        .target(name: "BASICDialectTraditional", dependencies: ["BASICCompilerKit"]),
        .target(name: "BASICRT"),
        .executableTarget(
            name: "basicc",
            dependencies: ["BASICCompilerKit", "BASICDialectTraditional"]
        ),
        .plugin(name: "BASICBuildPlugin", capability: .buildTool(), dependencies: ["basicc"]),
        .executableTarget(
            name: "basictest",
            dependencies: ["BASICCompilerKit", "BASICDialectTraditional"]
        ),
        .testTarget(
            name: "BASICCompilerKitTests",
            dependencies: ["BASICCompilerKit", "BASICDialectTraditional"]
        ),
    ]
)
