// swift-tools-version: 5.9
import PackageDescription

// The BASIC program's manifest: it names the framework, and selects Rev 2.
let package = Package(
    name: "Program",
    dependencies: [.package(path: "../Canvas")],
    targets: []
)
