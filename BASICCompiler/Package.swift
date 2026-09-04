// swift-tools-version: 6.0

import PackageDescription

// BASICCompiler — `basicc`, a BASIC compiler that builds LLVM modules and
// links against Swift libraries. A sibling of BASICShell and BASICStudio;
// see Documents/BASIC_COMPILER.md for the plan.
//
//   basicc                    the CLI driver
//   BASICCompilerKit          the shared dialect protocol, driver, BIR,
//                             diagnostics — owns no language knowledge
//   BASICDialectTraditional   the default dialect (Rev 1)
//   BASICRT                   the runtime library, in Swift, linked into
//                             every compiled program
//
// No external dependencies, by design: the compiler must build offline.
let package = Package(
    name: "BASICCompiler",
    platforms: [.macOS("16.0")],
    products: [
        .executable(name: "basicc", targets: ["basicc"]),
        .library(name: "BASICCompilerKit", targets: ["BASICCompilerKit"]),
        .library(name: "BASICDialectTraditional", targets: ["BASICDialectTraditional"]),
        .library(name: "BASICRT", type: .static, targets: ["BASICRT"]),
    ],
    targets: [
        .target(name: "BASICCompilerKit"),
        .target(name: "BASICDialectTraditional", dependencies: ["BASICCompilerKit"]),
        .target(name: "BASICRT"),
        .executableTarget(
            name: "basicc",
            dependencies: ["BASICCompilerKit", "BASICDialectTraditional"]
        ),
        .testTarget(
            name: "BASICCompilerKitTests",
            dependencies: ["BASICCompilerKit", "BASICDialectTraditional"]
        ),
    ]
)
