// swift-tools-version: 5.9
import PackageDescription

// The BASIC program's manifest. This is the whole of the dependency
// management: it names the package, and SwiftPM does the rest — basicc
// asks where it is, builds it, and reads its symbol graph. Nothing is
// fetched or resolved by the compiler itself.
//
// The presence of this file is also what selects the Rev 2 compiler
// (decision D11); `--dialect` overrides it either way.
let package = Package(
    name: "Program",
    dependencies: [.package(path: "../Shapes")],
    targets: []
)
