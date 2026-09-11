// swift-tools-version: 5.9
import PackageDescription

// A framework built the way Apple's are: with library evolution, so its
// classes are *resilient*. A subclass outside the module cannot know how big
// the base is or where its fields end — the layout is settled at run time —
// which is the case R1.5 exists for. Nothing here knows about BASIC.
let package = Package(
    name: "Canvas",
    platforms: [.macOS(.v13)],
    products: [.library(name: "Canvas", targets: ["Canvas"])],
    targets: [
        .target(name: "Canvas", swiftSettings: [.unsafeFlags(["-enable-library-evolution"])]),
    ]
)
