// swift-tools-version: 5.9
import PackageDescription

// An ordinary Swift package. Nothing here knows about BASIC.
let package = Package(
    name: "Shapes",
    products: [.library(name: "Shapes", targets: ["Shapes"])],
    targets: [.target(name: "Shapes")]
)
