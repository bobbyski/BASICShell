// swift-tools-version: 5.9
import PackageDescription

// An ordinary Swift package. Nothing here knows about BASIC.
let package = Package(
    name: "Shapes",
    // Concurrency needs a floor; an async method is unavailable below 10.15.
    platforms: [.macOS(.v13)],
    products: [.library(name: "Shapes", targets: ["Shapes"])],
    targets: [.target(name: "Shapes")]
)
