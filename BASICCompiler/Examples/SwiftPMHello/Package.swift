// swift-tools-version: 6.3;(experimentalCGen)
// `swift build` compiles BASIC. The header enables SwiftPM's support for
// plugin-generated C-family sources, which is how the assembly basicc emits
// reaches the linker. One stub .c keeps the target alive before the plugin
// runs; main.bas is excluded so clang never sees it.

import PackageDescription

let package = Package(
    name: "SwiftPMHello",
    platforms: [.macOS("16.0")],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "Hello",
            dependencies: [.product(name: "BASICRT", package: "BASICCompiler")],
            exclude: ["main.bas"],
            plugins: [.plugin(name: "BASICBuildPlugin", package: "BASICCompiler")]
        ),
    ]
)
